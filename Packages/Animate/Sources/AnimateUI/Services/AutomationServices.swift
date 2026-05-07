import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum AutomationSourceResolver {
    @MainActor
    static func projectSummary(store: AnimateStore, projectRoot: URL) -> AutomationProjectSummary {
        let scenes = store.scenes
        let shots = scenes.flatMap(\.shots)
        let songsCount = countFiles(in: projectRoot.appendingPathComponent("Songs"), extension: "ows")
        let characterRigCount = countRigJSON(in: projectRoot.appendingPathComponent("Characters"))
        var warnings: [String] = []
        let world = worldContext(projectRoot: projectRoot, warnings: &warnings)
        if let period = world?.timePeriod.lowercased(), period.contains("mid-2020s") {
            warnings.append("Canonical Places/places-world-context.json contains mid-2020s language; automation will not use stale duplicates, but the canonical file should be corrected.")
        }
        let projectionAudit = ShotCardProjectionAuditService(store: store).audit(projectRoot: projectRoot)
        for issue in projectionAudit.issues.prefix(8) {
            warnings.append(issue.blocker.message)
        }
        return AutomationProjectSummary(
            projectRoot: projectRoot.path,
            scenesCount: scenes.count,
            shotsCount: shots.count,
            placesCount: store.backgrounds.count,
            songsCount: songsCount,
            characterRigCount: characterRigCount,
            scenesWithBackgroundID: scenes.filter { $0.backgroundID != nil }.count,
            shotsWithPopulatedShotFrameGeneration: shots.filter { $0.shotFrameGeneration != nil }.count,
            shotsWithPopulatedShotBackgroundPlate: shots.filter { $0.shotBackgroundPlate != nil }.count,
            worldContext: world,
            warnings: warnings
        )
    }

    static func worldContext(projectRoot: URL, warnings: inout [String]) -> AutomationWorldContext? {
        let paths = ProjectPaths(root: projectRoot)
        let canonical = paths.placesWorldContextJSON
        let ignored = duplicateWorldContextPaths(projectRoot: projectRoot, canonical: canonical)
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            warnings.append("Missing canonical Places/places-world-context.json; refusing to silently fall back to stale duplicates/default mid-2020s context.")
            return nil
        }
        do {
            let data = try Data(contentsOf: canonical)
            let blocks = try JSONDecoder().decode(PlacesWorldContextBlocks.self, from: data)
            return AutomationWorldContext(
                sourcePath: canonical.path,
                timePeriod: blocks.timePeriod,
                environmental: blocks.environmental,
                aesthetic: blocks.aesthetic,
                ignoredDuplicatePaths: ignored
            )
        } catch {
            warnings.append("Could not read canonical Places/places-world-context.json: \(error.localizedDescription)")
            return nil
        }
    }

    static func automationDirectory(projectRoot: URL, component: String) -> URL {
        ProjectPaths(root: projectRoot).animate.appendingPathComponent(component, isDirectory: true)
    }

    private static func duplicateWorldContextPaths(projectRoot: URL, canonical: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "places-world-context.json",
                  url.standardizedFileURL.path != canonical.standardizedFileURL.path else { continue }
            paths.append(url.path)
        }
        return paths.sorted()
    }

    private static func countFiles(in directory: URL, extension ext: String) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return urls.filter { $0.pathExtension.lowercased() == ext.lowercased() }.count
    }

    private static func countRigJSON(in directory: URL) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        return urls.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("rig.json").path) }.count
    }
}

@available(macOS 26.0, *)
@MainActor
struct EffectiveShotSpecBuilder {
    var store: AnimateStore

    func build(scene: AnimationScene, shotIndex: Int, projectRoot: URL) -> EffectiveShotSpec {
        let shot = scene.shots[shotIndex]
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let promptProtocol = ShotPromptProtocolStore.load(projectRoot: projectRoot)
        var warnings: [String] = []
        let world = AutomationSourceResolver.worldContext(projectRoot: projectRoot, warnings: &warnings)
        let background = scene.backgroundID.flatMap { id in store.backgrounds.first { $0.id == id } }
        let shotCardContext = shotCardPromptContext(
            for: scene,
            shot: shot,
            shotIndex: shotIndex,
            projectRoot: projectRoot
        )
        let directorInput = ShotDirectorInputStore.read(projectRoot: projectRoot, sceneID: scene.id, shotID: shot.id)
        let acceptedDirectorNotes = ShotDirectorInputStore.acceptedNotes(for: directorInput)
        let focus = resolvedFocus(
            shotCardContext: shotCardContext,
            fallbackShot: shot,
            scene: scene
        )
        let sceneCharacters = characters(
            for: scene,
            focus: focus,
            contextualCharacters: shotCardContext?.characters ?? [],
            hasShotCardContext: shotCardContext != nil
        )
        let knownCharacterNames = Self.characterNameVariants(
            from: store.characters.map(\.name),
            sanitization: promptProtocol.sanitization
        )
        let action = Self.resolvedVisualAction(
            candidates: [
                acceptedDirectorNotes,
                shot.name,
                shotCardContext?.label,
                shotCardContext?.notes,
                shotCardContext?.continuityNotes,
                shot.sourceLyricExcerpt,
                shot.notes
            ],
            characterNames: knownCharacterNames,
            promptProtocol: promptProtocol
        )
        let enrichedAction = Self.enrichedVisualAction(
            action,
            shotCardContext: shotCardContext,
            shot: shot
        )
        let region = firstNonEmpty(world?.environmental, background?.geographicPlacement, background?.geographicPosition) ?? promptProtocol.visualSpec.templates.fallbackRegionText
        let materials = joinedNonEmpty([
            background?.visualBrief,
            background?.physicalDescription,
            background?.physicalLayoutAndTopography,
            background?.coreIdentity,
            background?.keyPropsSetDressing
        ], separator: "\n")
        let lighting = firstNonEmpty(
            Self.contextualLightingCue(
                from: shotCardContext,
                visualText: joinedNonEmpty([
                    shot.name,
                    shotCardContext?.label,
                    shotCardContext?.notes,
                    shot.sourceLyricExcerpt,
                    shot.notes
                ], separator: "\n")
            ),
            background?.visualPaletteLighting,
            background?.timeOfDay,
            background?.dayLabel
        ) ?? promptProtocol.visualSpec.templates.fallbackLightingText
        let camera = joinedNonEmpty([
            shot.cameraShot?.displayName,
            background?.cameraFramingNotes,
            shotCardContext?.cameraCue
        ], separator: "; ")
        let styleLock = animatedLookPrompt(projectRoot: projectRoot)
        let visualTone = shotSettings.useMinimalShotPrompts
            ? promptProtocol.visualSpec.templates.minimalVisualToneText
            : joinedNonEmpty([
                styleLock
            ], separator: "\n\n")
        let resolvedVisualTone = visualTone.isEmpty ? promptProtocol.visualSpec.templates.fallbackVisualToneText : visualTone
        var blockers: [AutomationBlocker] = []
        if let projectionIssue = ShotCardProjectionAuditService(store: store)
            .auditIssue(scene: scene, projectRoot: projectRoot) {
            blockers.append(projectionIssue.blocker)
        }
        if scene.backgroundID == nil {
            blockers.append(.init(code: .blockedMissingPlace, message: "Scene has no backgroundID; automation cannot resolve a canonical place.", field: "backgroundID"))
        } else if background == nil {
            blockers.append(.init(code: .blockedMissingPlace, message: "Scene backgroundID does not match a loaded place/background.", field: "backgroundID"))
        }
        if (shot.focusCharacterID != nil || shot.focusCharacterSlug != nil), focus == nil {
            blockers.append(.init(code: .blockedMissingCharacter, message: "Shot focus character does not match a loaded character package.", field: "focusCharacter"))
        }
        if world == nil {
            blockers.append(.init(code: .blockedMissingReferenceRole, message: "Missing canonical world context from Places/places-world-context.json.", field: "worldContext"))
        }
        if let directorInput,
           !directorInput.isAccepted,
           joinedNonEmpty([directorInput.transcriptText, directorInput.sketchAnalysisPath], separator: " ").isEmpty == false {
            blockers.append(.init(
                code: .blockedUnacceptedDirectorInput,
                message: "Shot has proposed Shot Director input that has not been accepted; review or reject it before paid generation.",
                field: "Animate/director-inputs",
                severity: "warning"
            ))
        }
        let negativeGuardrails = guardrails(world: world, background: background, promptProtocol: promptProtocol)
        let reviewFeedback: [String]
        if shotSettings.includeReviewFeedbackInShotPrompts {
            let feedbackQuery = joinedNonEmpty([
                scene.name,
                shot.name,
                enrichedAction,
                background?.name,
                background?.visualBrief,
                focus?.name,
                focus?.description
            ], separator: "\n")
            var preferenceRoles: [ImageLibrarySemanticRole] = []
            if background != nil { preferenceRoles.append(.place) }
            if focus != nil || !sceneCharacters.isEmpty { preferenceRoles.append(.character) }
            reviewFeedback = ImageReviewFeedbackService.promptClauses(
                from: ImageReviewFeedbackService.relevantFeedback(
                    projectRoot: projectRoot,
                    query: feedbackQuery,
                    limit: 6
                )
            ) + ContinuityRuleExtractionService.relevantPromptClauses(
                projectRoot: projectRoot,
                query: feedbackQuery,
                limit: 8
            ) + ImagePreferenceProfileService.relevantPromptClauses(
                projectRoot: projectRoot,
                query: feedbackQuery,
                semanticRoles: preferenceRoles.isEmpty ? nil : preferenceRoles,
                limit: 8
            )
        } else {
            reviewFeedback = []
        }
        let prompt = Self.prompt(
            scene: scene,
            shot: shot,
            background: background,
            focus: focus,
            characters: sceneCharacters,
            characterLayoutCue: Self.characterLayoutCue(from: shotCardContext),
            action: enrichedAction,
            worldPeriod: world?.timePeriod ?? "UNKNOWN — read Places/places-world-context.json before executing paid generation.",
            region: region,
            materials: materials,
            lighting: lighting,
            camera: camera,
            visualTone: resolvedVisualTone,
            negativeGuardrails: negativeGuardrails,
            reviewFeedback: reviewFeedback,
            minimal: shotSettings.useMinimalShotPrompts,
            forbidVisibleFrameGuides: shotSettings.forbidVisibleFrameGuides,
            promptProtocol: promptProtocol
        )
        let visualContract = visualContract(
            source: "active_ows_camera_card",
            shotIndex: shotIndex,
            shotCardContext: shotCardContext,
            acceptedDirectorNotes: acceptedDirectorNotes
        )
        let resolvedFocusCharacterID = shotCardContext == nil ? (shot.focusCharacterID ?? focus?.id) : focus?.id
        let resolvedFocusCharacterSlug = shotCardContext == nil ? (shot.focusCharacterSlug ?? focus?.owpSlug) : focus?.owpSlug
        var spec = EffectiveShotSpec(
            id: shot.id,
            createdAt: Date(),
            source: shotCardContext == nil ? "Scenes/scenes.json" : "active_ows_camera_card",
            sceneID: scene.id,
            sceneName: scene.name,
            shotID: shot.id,
            shotIndex: shotIndex,
            shotName: shot.name,
            shotCardLabel: shotCardContext?.label,
            shotCardFocus: shotCardContext?.focus,
            shotCardNotes: shotCardContext?.notes,
            shotCardContinuityNotes: shotCardContext?.continuityNotes,
            shotCardPlaces: shotCardContext?.places,
            shotCardProps: shotCardContext?.props,
            shotCardLandmarks: shotCardContext?.landmarks,
            visualContract: visualContract,
            startFrame: shot.startFrame,
            endFrame: shot.endFrame,
            backgroundID: scene.backgroundID,
            backgroundName: background?.name,
            approvedPlaceImagePath: resolvedPath(background?.approvedImagePath, projectRoot: projectRoot),
            focusCharacterID: resolvedFocusCharacterID,
            focusCharacterSlug: resolvedFocusCharacterSlug,
            focusCharacterName: focus?.name,
            characterIDs: sceneCharacters.map(\.id),
            characterSlugs: sceneCharacters.map { characterSlug($0) },
            characterNames: sceneCharacters.map(\.name),
            cameraShot: shot.cameraShot?.rawValue,
            shotIntent: shot.shotIntent?.rawValue,
            action: enrichedAction,
            notes: shot.notes,
            lyricExcerpt: shot.sourceLyricExcerpt,
            worldPeriod: world?.timePeriod ?? "",
            regionalWorldCues: region,
            architectureMaterials: materials,
            lighting: lighting,
            cameraFraming: camera,
            visualTone: resolvedVisualTone,
            negativeGuardrails: negativeGuardrails,
            prompt: prompt,
            blockers: blockers
        )
        spec.blockers.append(contentsOf: ShotSpecValidationService().contentBlockers(for: spec))
        return spec
    }

    func write(_ spec: EffectiveShotSpec, projectRoot: URL) throws -> URL {
        let dir = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-specs")
            .appendingPathComponent(spec.sceneID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(spec.shotID.uuidString).json")
        try writeCodable(spec, to: url)
        return url
    }

    private func focusedCharacter(for shot: AnimationSceneShot, scene: AnimationScene) -> AnimationCharacter? {
        if let id = shot.focusCharacterID,
           let match = store.characters.first(where: { $0.id == id }) { return match }
        if let slug = shot.focusCharacterSlug?.lowercased(), !slug.isEmpty,
           let match = store.characters.first(where: { characterSlug($0).lowercased() == slug || $0.owpSlug.lowercased() == slug }) { return match }
        if let id = scene.characterIDs.first,
           let match = store.characters.first(where: { $0.id == id }) { return match }
        if let slug = scene.characterSlugs.first?.lowercased(),
           let match = store.characters.first(where: { characterSlug($0).lowercased() == slug || $0.owpSlug.lowercased() == slug }) { return match }
        return nil
    }

    private func characters(
        for scene: AnimationScene,
        focus: AnimationCharacter?,
        contextualCharacters: [AnimationCharacter],
        hasShotCardContext: Bool
    ) -> [AnimationCharacter] {
        var result: [AnimationCharacter] = []
        if let focus, !hasShotCardContext { result.append(focus) }
        for character in contextualCharacters where !result.contains(where: { $0.id == character.id }) {
            result.append(character)
        }
        if hasShotCardContext {
            return result
        }
        for id in scene.characterIDs {
            if let c = store.characters.first(where: { $0.id == id }), !result.contains(where: { $0.id == c.id }) { result.append(c) }
        }
        for slug in scene.characterSlugs.map({ $0.lowercased() }) {
            if let c = store.characters.first(where: { characterSlug($0).lowercased() == slug || $0.owpSlug.lowercased() == slug }), !result.contains(where: { $0.id == c.id }) { result.append(c) }
        }
        return result
    }

    private func resolvedFocus(
        shotCardContext: ShotCardPromptContext?,
        fallbackShot: AnimationSceneShot,
        scene: AnimationScene
    ) -> AnimationCharacter? {
        if let token = shotCardContext?.focus,
           let character = resolveCharacter(fromToken: token) {
            return character
        }
        guard shotCardContext == nil else { return nil }
        return focusedCharacter(for: fallbackShot, scene: scene)
    }

    private func guardrails(
        world: AutomationWorldContext?,
        background: BackgroundPlate?,
        promptProtocol: ShotPromptProtocolSettings
    ) -> [String] {
        var values: [String] = []
        if let world {
            values += world.timePeriod.components(separatedBy: .newlines).dropFirst().map { String($0) }
        }
        values.append(background?.imageGenerationGuardrails ?? "")
        values.append(contentsOf: promptProtocol.visualSpec.templates.defaultGuardrails)
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func prompt(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        background: BackgroundPlate?,
        focus: AnimationCharacter?,
        characters: [AnimationCharacter],
        characterLayoutCue: String,
        action: String,
        worldPeriod: String,
        region: String,
        materials: String,
        lighting: String,
        camera: String,
        visualTone: String,
        negativeGuardrails: [String],
        reviewFeedback: [String],
        minimal: Bool,
        forbidVisibleFrameGuides: Bool,
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        _ = scene
        _ = shot
        _ = background
        _ = focus
        _ = worldPeriod

        let characterNames = characterNameVariants(
            from: characters.map(\.name),
            sanitization: promptProtocol.sanitization
        )
        let cleanedAction = cleanedVisualText(action, characterNames: characterNames, promptProtocol: promptProtocol)
        let cleanedRegion = cleanedVisualText(
            firstSentence(from: firstLine(of: region) ?? region, sanitization: promptProtocol.sanitization),
            characterNames: characterNames,
            promptProtocol: promptProtocol
        )
        let cleanedMaterials = cleanedVisualText(
            firstSentence(from: firstLine(of: materials) ?? materials, sanitization: promptProtocol.sanitization),
            characterNames: characterNames,
            promptProtocol: promptProtocol
        )
        let cleanedCamera = cleanedVisualText(
            firstSentence(from: firstLine(of: camera) ?? camera, sanitization: promptProtocol.sanitization),
            characterNames: characterNames,
            promptProtocol: promptProtocol
        )
        let cleanedLighting = cleanedVisualText(
            firstSentence(from: firstLine(of: lighting) ?? lighting, sanitization: promptProtocol.sanitization),
            characterNames: characterNames,
            promptProtocol: promptProtocol
        )
        let cleanedTone = cleanedVisualText(
            firstSentence(from: firstLine(of: visualTone) ?? visualTone, sanitization: promptProtocol.sanitization),
            characterNames: characterNames,
            promptProtocol: promptProtocol
        )

        var lines: [String] = []
        let fallbackCharacterCue = visualCharacterCue(
            characters: characters,
            fallbackNames: characterNames,
            promptProtocol: promptProtocol
        )
        let characterCue = firstNonEmpty(characterLayoutCue, fallbackCharacterCue) ?? ""
        let cleanedGuardrails = negativeGuardrails
            .map {
                cleanedVisualText($0, characterNames: characterNames, promptProtocol: promptProtocol)
            }
            .filter { !$0.isEmpty }

        let environmentCue: String = {
            switch promptProtocol.visualSpec.environmentSourceMode {
            case .regionOnly:
                return cleanedRegion.isEmpty ? cleanedMaterials : cleanedRegion
            case .regionThenMaterials:
                return joinedNonEmpty([cleanedRegion, cleanedMaterials], separator: ". ")
            }
        }()

        let reviewLine: String? = {
            guard !minimal,
                  !reviewFeedback.isEmpty else { return nil }
            let cleanedFeedback = reviewFeedback
                .map {
                    cleanedVisualText($0, characterNames: characterNames, promptProtocol: promptProtocol)
                }
                .filter { !$0.isEmpty }
            guard !cleanedFeedback.isEmpty else { return nil }
            return ShotPromptProtocolStore.applyTemplate(
                promptProtocol.visualSpec.templates.reviewFeedbackLineTemplate,
                values: ["feedback": cleanedFeedback.joined(separator: " | ")]
            )
        }()

        let cleanOutputLine = forbidVisibleFrameGuides
            ? promptProtocol.visualSpec.templates.cleanOutputWhenGuidesForbidden
            : promptProtocol.visualSpec.templates.cleanOutputDefault

        for section in promptProtocol.visualSpec.sectionOrder {
            switch section {
            case .action:
                if !cleanedAction.isEmpty { lines.append(cleanedAction) }
            case .environment:
                if !environmentCue.isEmpty { lines.append(environmentCue) }
            case .camera:
                if !cleanedCamera.isEmpty {
                    lines.append(
                        ShotPromptProtocolStore.applyTemplate(
                            promptProtocol.visualSpec.templates.cameraLineTemplate,
                            values: ["camera": cleanedCamera]
                        )
                    )
                }
            case .lighting:
                if !cleanedLighting.isEmpty {
                    lines.append(
                        ShotPromptProtocolStore.applyTemplate(
                            promptProtocol.visualSpec.templates.lightingLineTemplate,
                            values: ["lighting": cleanedLighting]
                        )
                    )
                }
            case .characters:
                if !characterCue.isEmpty { lines.append(characterCue) }
            case .style:
                if !cleanedTone.isEmpty { lines.append(cleanedTone) }
            case .guardrail:
                if let firstGuardrail = cleanedGuardrails.first {
                    lines.append(firstGuardrail)
                }
            case .review:
                if let reviewLine { lines.append(reviewLine) }
            case .cleanOutput:
                if !cleanOutputLine.isEmpty { lines.append(cleanOutputLine) }
            }
        }

        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func resolvedVisualAction(
        candidates: [String?],
        characterNames: [String],
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        for candidate in candidates {
            let cleaned = cleanedVisualText(candidate, characterNames: characterNames, promptProtocol: promptProtocol)
            if !cleaned.isEmpty,
               !isLowSignalActionLine(cleaned),
               !isNarrativeOrMotivationLine(cleaned) {
                return cleaned
            }
        }
        return promptProtocol.visualSpec.templates.fallbackActionText
    }

    private static func isLowSignalActionLine(_ value: String) -> Bool {
        let lower = value.lowercased()
        let disallowedPhrases = [
            "seeded from script line",
            "first time",
            "for the first time",
            "beginning frame",
            "middle frame",
            "end frame",
            "scene",
            "shot"
        ]
        if disallowedPhrases.contains(where: { lower.contains($0) }) {
            return true
        }
        let tokenCount = lower
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
        return tokenCount <= 3
    }

    private static func isNarrativeOrMotivationLine(_ value: String) -> Bool {
        let lower = value.lowercased()
        let disallowedPhrases = [
            "official record",
            "mission",
            "for what the job asks",
            "what the job asks",
            "personal record",
            "private record",
            "because",
            "so that",
            "longs",
            "wants to",
            "needs to",
            "decides to",
            "realizes",
            "understands",
            "remembers",
            "why the shot exists",
            "dramatic",
            "motivation",
            "story beat",
            "script"
        ]
        return disallowedPhrases.contains { lower.contains($0) }
    }

    private static func enrichedVisualAction(
        _ action: String,
        shotCardContext: ShotCardPromptContext?,
        shot: AnimationSceneShot
    ) -> String {
        var parts = [action.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let contextText = joinedNonEmpty([
            action,
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt,
            shotCardContext?.label,
            shotCardContext?.notes,
            shotCardContext?.continuityNotes,
            shotCardContext?.places.joined(separator: " "),
            shotCardContext?.landmarks.joined(separator: " ")
        ], separator: "\n").lowercased()

        if isVehicleInteriorShotText(contextText) {
            parts.append("Interior of a tan military Humvee cabin; visible seats, dashboard or windows, and occupants placed naturally in the vehicle seats with realistic body scale.")
        }

        if containsAny(contextText, terms: ["convoy", "humvee", "vehicle", "road", "driving"]) {
            parts.append("Tan Humvees and military vehicle details should read clearly, with desert dust, road position, and wheel direction matching the described movement.")
        }

        if containsAny(contextText, terms: ["valley", "mountain", "ridge", "river", "road", "wide", "establishing", "outside town"]) {
            parts.append("Wide exterior geography should show the mountain valley, rugged slopes, winding road, and river relationship clearly.")
        }

        return deduplicateSentences(parts).joined(separator: " ")
    }

    private static func contextualLightingCue(
        from context: ShotCardPromptContext?,
        visualText: String
    ) -> String? {
        guard let context else { return nil }
        let text = visualText.lowercased()
        var interiorExterior = context.interiorExterior?.trimmingCharacters(in: .whitespacesAndNewlines)

        if containsAny(text, terms: ["cabin", "interior", "inside", "dashboard", "windshield", "seat", "seated"]) {
            interiorExterior = "Interior vehicle cabin; exterior landscape visible through windows only"
        } else if let raw = interiorExterior?.lowercased(),
                  raw.contains("exterior"),
                  containsAny(text, terms: ["valley", "mountain", "road", "river", "convoy", "outside town"]) {
            interiorExterior = "Exterior mountain valley environment with open sky"
        }

        return joinedNonEmpty([
            context.timeOfDay,
            interiorExterior,
            context.weatherAtmosphere,
            context.lightSource
        ], separator: ", ")
    }

    private static func visualCharacterCue(
        characters: [AnimationCharacter],
        fallbackNames: [String],
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        guard !characters.isEmpty else { return "" }
        let descriptors = characters.compactMap { character -> String? in
            let base = firstNonEmpty(
                firstLine(of: character.promptNotes),
                firstLine(of: character.description),
                firstLine(of: character.notes)
            )
            let cleaned = cleanedVisualText(base, characterNames: fallbackNames, promptProtocol: promptProtocol)
            let concise = leadingSentences(
                from: cleaned,
                maxCount: promptProtocol.visualSpec.characterSentenceLimit
            )
            return concise.isEmpty ? nil : concise
        }
        guard !descriptors.isEmpty else { return "" }
        if descriptors.count == 1 {
            return descriptors[0]
        }
        return descriptors.joined(separator: " ")
    }

    private struct ShotCardPromptContext {
        var sourceLineNumber: Int?
        var cameraCardIndex: Int
        var cameraCardCount: Int
        var label: String?
        var characters: [AnimationCharacter]
        var leftCharacters: [AnimationCharacter]
        var middleCharacters: [AnimationCharacter]
        var rightCharacters: [AnimationCharacter]
        var leftFacing: String?
        var middleFacing: String?
        var rightFacing: String?
        var timeOfDay: String?
        var interiorExterior: String?
        var weatherAtmosphere: String?
        var lightSource: String?
        var lens: String?
        var cameraAngle: String?
        var depthOfField: String?
        var continuityNotes: String?
        var notes: String?
        var focus: String?
        var places: [String]
        var props: [String]
        var landmarks: [String]

        var cameraCue: String {
            joinedNonEmpty([lens, cameraAngle, depthOfField], separator: ", ")
        }

        var lightingCue: String {
            joinedNonEmpty([timeOfDay, interiorExterior, weatherAtmosphere, lightSource], separator: ", ")
        }
    }

    private func visualContract(
        source: String,
        shotIndex: Int,
        shotCardContext context: ShotCardPromptContext?,
        acceptedDirectorNotes: String?
    ) -> ShotVisualContract? {
        guard let context else { return nil }
        let visibleCharacters = deduplicatedNames(
            (context.characters + context.leftCharacters + context.middleCharacters + context.rightCharacters)
                .map(\.name)
        )
        return ShotVisualContract(
            source: source,
            sourceLineNumber: context.sourceLineNumber,
            cameraCardIndex: context.cameraCardIndex,
            cameraCardCount: context.cameraCardCount,
            label: context.label,
            focus: context.focus,
            visibleCharacters: visibleCharacters,
            leftCharacters: context.leftCharacters.map(\.name),
            middleCharacters: context.middleCharacters.map(\.name),
            rightCharacters: context.rightCharacters.map(\.name),
            leftFacing: context.leftFacing,
            middleFacing: context.middleFacing,
            rightFacing: context.rightFacing,
            places: context.places,
            props: context.props,
            landmarks: context.landmarks,
            timeOfDay: context.timeOfDay,
            interiorExterior: context.interiorExterior,
            weatherAtmosphere: context.weatherAtmosphere,
            lightSource: context.lightSource,
            lens: context.lens,
            cameraAngle: context.cameraAngle,
            depthOfField: context.depthOfField,
            continuityNotes: context.continuityNotes,
            notes: context.notes,
            acceptedDirectorNotes: acceptedDirectorNotes
        )
    }

    private func deduplicatedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func characterLayoutCue(from context: ShotCardPromptContext?) -> String {
        guard let context else { return "" }
        let placements: [(label: String, count: Int, facing: String?)] = [
            ("left", context.leftCharacters.count, context.leftFacing),
            ("middle", context.middleCharacters.count, context.middleFacing),
            ("right", context.rightCharacters.count, context.rightFacing)
        ]
        let placementDescriptions = placements.compactMap { placement -> String? in
            guard placement.count > 0 else { return nil }
            let subjectText = placement.count == 1 ? "subject" : "subjects"
            let facingText = placement.facing?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? " facing \(placement.facing!.trimmingCharacters(in: .whitespacesAndNewlines))"
                : ""
            return "\(placement.count) \(subjectText) on the \(placement.label)\(facingText)"
        }

        let placementLine = placementDescriptions.isEmpty
            ? ""
            : "Character placement: \(placementDescriptions.joined(separator: "; "))."
        let referenceLine = context.characters.isEmpty
            ? ""
            : "Match identity, wardrobe, and accessories to the attached character references."

        return joinedNonEmpty([placementLine, referenceLine], separator: " ")
    }

    private func shotCardPromptContext(
        for scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int,
        projectRoot: URL
    ) -> ShotCardPromptContext? {
        guard let lyrics = activeLyricsText(for: scene, projectRoot: projectRoot),
              !lyrics.isEmpty else { return nil }
        let parsed = SceneDirectionParser.parse(lyrics)
        let cameraDirections = parsed.directions.filter { $0.tag == .camera }
        guard let direction = matchedCameraDirection(
            for: shot,
            shotIndex: shotIndex,
            directions: cameraDirections
        ) else {
            return nil
        }
        let cameraCardIndex = cameraDirections.firstIndex(where: { $0.id == direction.id }) ?? shotIndex

        let parameters = direction.parameters
        let rawCharacters = splitList(
            firstNonEmpty(
                parameters["characters"],
                parameters["character"],
                parameters["cast"]
            )
        )
        let rawLeft = splitList(
            firstNonEmpty(
                parameters["character_left"],
                parameters["characterleft"],
                parameters["characters_left"],
                parameters["left_characters"]
            )
        )
        let rawMiddle = splitList(
            firstNonEmpty(
                parameters["character_middle"],
                parameters["charactermiddle"],
                parameters["characters_middle"],
                parameters["middle_characters"]
            )
        )
        let rawRight = splitList(
            firstNonEmpty(
                parameters["character_right"],
                parameters["characterright"],
                parameters["characters_right"],
                parameters["right_characters"]
            )
        )

        let contextualCharacters = resolveCharacters(fromTokens: rawCharacters + rawLeft + rawMiddle + rawRight)
        let leftCharacters = resolveCharacters(fromTokens: rawLeft)
        let middleCharacters = resolveCharacters(fromTokens: rawMiddle)
        let rightCharacters = resolveCharacters(fromTokens: rawRight)

        return ShotCardPromptContext(
            sourceLineNumber: direction.sourceLineNumber,
            cameraCardIndex: cameraCardIndex,
            cameraCardCount: cameraDirections.count,
            label: firstNonEmpty(parameters["label"], parameters["name"]),
            characters: contextualCharacters,
            leftCharacters: leftCharacters,
            middleCharacters: middleCharacters,
            rightCharacters: rightCharacters,
            leftFacing: firstNonEmpty(
                parameters["character_left_facing"],
                parameters["characters_left_facing"],
                parameters["left_character_facing"],
                parameters["left_facing"]
            ),
            middleFacing: firstNonEmpty(
                parameters["character_middle_facing"],
                parameters["characters_middle_facing"],
                parameters["middle_character_facing"],
                parameters["middle_facing"]
            ),
            rightFacing: firstNonEmpty(
                parameters["character_right_facing"],
                parameters["characters_right_facing"],
                parameters["right_character_facing"],
                parameters["right_facing"]
            ),
            timeOfDay: firstNonEmpty(parameters["time_of_day"], parameters["timeofday"], parameters["time"]),
            interiorExterior: firstNonEmpty(parameters["interior_exterior"], parameters["interiorexterior"]),
            weatherAtmosphere: firstNonEmpty(parameters["weather_atmosphere"], parameters["weatheratmosphere"]),
            lightSource: firstNonEmpty(parameters["light_source"], parameters["lightsource"]),
            lens: parameters["lens"],
            cameraAngle: firstNonEmpty(parameters["camera_angle"], parameters["cameraangle"], parameters["angle"]),
            depthOfField: firstNonEmpty(parameters["depth_of_field"], parameters["depthoffield"], parameters["dof"]),
            continuityNotes: firstNonEmpty(parameters["continuity_notes"], parameters["continuitynotes"], parameters["continuity"]),
            notes: firstNonEmpty(parameters["notes"], parameters["description"]),
            focus: parameters["focus"],
            places: splitList(parameters["places"]),
            props: splitList(parameters["props"]),
            landmarks: splitList(parameters["landmarks"])
        )
    }

    private func activeLyricsText(for scene: AnimationScene, projectRoot: URL) -> String? {
        guard let songPath = sceneSongPath(scene) else { return nil }
        let songURL = projectRoot.appendingPathComponent(songPath)
        guard let data = try? Data(contentsOf: songURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = root["versions"] as? [[String: Any]],
              !versions.isEmpty else {
            return nil
        }

        let activeID = (root["activeVersionID"] as? String)?.uppercased()
        let selectedVersion: [String: Any] = activeID.flatMap { id in
            versions.first { (($0["id"] as? String) ?? "").uppercased() == id }
        } ?? versions[versions.count - 1]

        if let lyrics = selectedVersion["lyrics"] as? String, !lyrics.isEmpty {
            return lyrics
        }
        if let lyrics = selectedVersion["librettoText"] as? String, !lyrics.isEmpty {
            return lyrics
        }
        if let snapshot = selectedVersion["playbackSnapshot"] as? [String: Any] {
            if let lyrics = snapshot["lyrics"] as? String, !lyrics.isEmpty {
                return lyrics
            }
            if let lyrics = snapshot["librettoText"] as? String, !lyrics.isEmpty {
                return lyrics
            }
            if let lines = snapshot["lyricsLines"] as? [String], !lines.isEmpty {
                return lines.joined(separator: "\n")
            }
        }
        return nil
    }

    private func sceneSongPath(_ scene: AnimationScene) -> String? {
        let direct = scene.owpSongPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return direct
        }
        if let legacy = Mirror(reflecting: scene).children.first(where: { $0.label == "owsSongPath" })?.value as? String {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func matchedCameraDirection(
        for shot: AnimationSceneShot,
        shotIndex: Int,
        directions: [SceneDirection]
    ) -> SceneDirection? {
        guard !directions.isEmpty else { return nil }

        if let lineNumber = shot.sourceLineNumber,
           let exactLine = directions.first(where: { $0.sourceLineNumber == lineNumber }) {
            return exactLine
        }

        let shotLabel = normalizedLabel(shot.name)
        if !shotLabel.isEmpty {
            let labelMatches = directions.filter { normalizedLabel($0.parameters["label"] ?? "") == shotLabel }
            if labelMatches.count == 1 {
                return labelMatches[0]
            }
            if let lineNumber = shot.sourceLineNumber, !labelMatches.isEmpty {
                return labelMatches.min(by: { abs($0.sourceLineNumber - lineNumber) < abs($1.sourceLineNumber - lineNumber) })
            }
        }

        let shotSemanticTokens = semanticTokens(
            from: [shot.name, shot.notes, shot.sourceLyricExcerpt ?? ""]
                .joined(separator: " ")
        )
        if !shotSemanticTokens.isEmpty {
            let scored = directions.compactMap { direction -> (direction: SceneDirection, score: Int, lineDistance: Int)? in
                let directionTokens = semanticTokens(
                    from: [
                        direction.parameters["label"] ?? "",
                        direction.parameters["focus"] ?? "",
                        direction.parameters["notes"] ?? "",
                        direction.parameters["intent"] ?? ""
                    ].joined(separator: " ")
                )
                guard !directionTokens.isEmpty else { return nil }
                let overlapCount = shotSemanticTokens.intersection(directionTokens).count
                guard overlapCount > 0 else { return nil }
                let lineDistance = shot.sourceLineNumber.map { abs(direction.sourceLineNumber - $0) } ?? Int.max
                let score = overlapCount * 2
                return (direction: direction, score: score, lineDistance: lineDistance)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.lineDistance != rhs.lineDistance { return lhs.lineDistance < rhs.lineDistance }
                return lhs.direction.sourceLineNumber < rhs.direction.sourceLineNumber
            }
            if let best = scored.first {
                return best.direction
            }
        }

        if let lineNumber = shot.sourceLineNumber {
            let nearestByLine = directions.min(by: { abs($0.sourceLineNumber - lineNumber) < abs($1.sourceLineNumber - lineNumber) })
            if let nearestByLine {
                return nearestByLine
            }
        }

        if shotIndex >= 0, shotIndex < directions.count {
            return directions[shotIndex]
        }
        return directions.first
    }

    private func normalizedLabel(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitList(_ value: String?) -> [String] {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func semanticTokens(from value: String) -> Set<String> {
        let lowered = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "of", "to", "in", "on", "at",
            "for", "with", "from", "by", "as", "is", "are", "be", "this",
            "that", "shot", "scene", "seeded", "script", "line"
        ]
        let tokens = lowered
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        return Set(tokens)
    }

    private func resolveCharacters(fromTokens tokens: [String]) -> [AnimationCharacter] {
        var result: [AnimationCharacter] = []
        for token in tokens {
            guard let character = resolveCharacter(fromToken: token) else { continue }
            if !result.contains(where: { $0.id == character.id }) {
                result.append(character)
            }
        }
        return result
    }

    private func resolveCharacter(fromToken rawToken: String) -> AnimationCharacter? {
        let token = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !token.isEmpty else { return nil }

        return store.characters.first { character in
            let aliases = characterAliases(for: character)
            return aliases.contains(token)
        }
    }

    private func characterAliases(for character: AnimationCharacter) -> Set<String> {
        let name = character.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let primarySlug = characterSlug(character).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fallbackSlug = character.owpSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let firstName = name.split(separator: " ").first.map(String.init) ?? ""
        let compactName = name.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return Set([name, primarySlug, fallbackSlug, firstName, compactName].filter { !$0.isEmpty })
    }

    private static func cleanedVisualText(
        _ value: String?,
        characterNames: [String],
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "" }

        text = replacingRegex(
            in: text,
            pattern: promptProtocol.sanitization.seededScriptLinePattern,
            with: ""
        )
        for pattern in promptProtocol.sanitization.additionalStripPatterns {
            text = replacingRegex(in: text, pattern: pattern, with: "")
        }
        if promptProtocol.sanitization.stripBracketedSpans {
            text = replacingRegex(in: text, pattern: #"\[[^\]]*\]"#, with: "")
        }
        if promptProtocol.sanitization.stripResidualSquareBrackets {
            text = replacingRegex(in: text, pattern: #"\["#, with: "")
            text = replacingRegex(in: text, pattern: #"\]"#, with: "")
        }
        if promptProtocol.sanitization.collapseWhitespace {
            text = replacingRegex(in: text, pattern: #"\s+"#, with: " ")
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in characterNames {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: trimmedName)
            cleaned = replacingRegex(
                in: cleaned,
                pattern: "(?i)\\b\(escaped)\\b",
                with: promptProtocol.sanitization.replaceCharacterNamesWith
            )
        }
        if promptProtocol.sanitization.collapseWhitespace {
            cleaned = replacingRegex(in: cleaned, pattern: #"\s+"#, with: " ")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func characterNameVariants(
        from names: [String],
        sanitization: ShotPromptSanitization
    ) -> [String] {
        var set = Set<String>()
        for rawName in names {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            set.insert(trimmed)
            if sanitization.includeNameFragments {
                for part in trimmed.split(separator: " ").map(String.init)
                where part.count >= sanitization.minimumNameFragmentLength {
                    set.insert(part)
                }
            }
        }
        return Array(set).sorted { $0.count > $1.count }
    }

    private static func firstSentence(
        from value: String,
        sanitization: ShotPromptSanitization
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        for delimiter in sanitization.firstSentenceDelimiters {
            if let range = trimmed.range(of: delimiter) {
                let prefix = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return prefix
                }
            }
        }
        return trimmed
    }

    private static func leadingSentences(from value: String, maxCount: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxCount > 0 else { return "" }
        let parts = trimmed
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return trimmed }
        return parts.prefix(maxCount).joined(separator: ". ") + "."
    }

    private static func replacingRegex(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains(where: { text.contains($0) })
    }

    private static func isVehicleInteriorShotText(_ text: String) -> Bool {
        containsAny(
            text.lowercased(),
            terms: [
                "vehicle interior",
                "humvee interior",
                "military vehicle interior",
                "inside a military vehicle",
                "inside the military vehicle",
                "inside a vehicle",
                "inside the vehicle",
                "inside a humvee",
                "inside the humvee",
                "inside the cabin",
                "in the cabin",
                "cabin interior",
                "dashboard",
                "windshield",
                "seated inside",
                "seated in the vehicle",
                "seated in the humvee",
                "from inside the vehicle",
                "from inside the humvee",
                "through the windshield"
            ]
        )
    }

    private static func deduplicateSentences(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

@available(macOS 26.0, *)
struct ShotSpecValidationService {
    func validate(_ spec: EffectiveShotSpec) -> [AutomationBlocker] {
        spec.blockers
    }

    func contentBlockers(for spec: EffectiveShotSpec) -> [AutomationBlocker] {
        var blockers: [AutomationBlocker] = []
        let combinedText = [
            spec.shotName,
            spec.shotCardLabel ?? "",
            spec.action,
            spec.notes,
            spec.shotCardNotes ?? "",
            spec.shotCardContinuityNotes ?? "",
            spec.lighting,
            spec.cameraFraming,
            spec.prompt,
            spec.visualContract?.acceptedDirectorNotes ?? ""
        ]
        .joined(separator: "\n")
        .lowercased()

        let forbiddenTerms = [
            "power line",
            "power lines",
            "utility pole",
            "telephone pole",
            "overhead wire",
            "overhead wires"
        ]
        if let term = forbiddenTerms.first(where: { combinedText.contains($0) }) {
            blockers.append(.init(
                code: .blockedForbiddenPromptTerm,
                message: "Visual contract contains forbidden modern infrastructure term '\(term)'. Remove it before generation.",
                field: "prompt"
            ))
        }

        if let contract = spec.visualContract {
            if contract.places.isEmpty {
                blockers.append(.init(
                    code: .blockedMissingPlace,
                    message: "Active shot card has no places tag; generation needs a canonical location identity.",
                    field: "visualContract.places"
                ))
            }
            let interiorExterior = (contract.interiorExterior ?? "").lowercased()
            let saysInterior = interiorExterior.contains("interior")
                || combinedText.contains("inside the vehicle")
                || combinedText.contains("inside a vehicle")
                || combinedText.contains("cabin interior")
            let saysOpenSky = combinedText.contains("open sky")
                || combinedText.contains("wide exterior")
                || combinedText.contains("exterior mountain valley")
            let windowException = combinedText.contains("through the window")
                || combinedText.contains("through windows")
                || combinedText.contains("through the windshield")
            if saysInterior && saysOpenSky && !windowException {
                blockers.append(.init(
                    code: .blockedVisualContractConflict,
                    message: "Visual contract mixes an interior setup with open-sky/exterior staging without a window/windshield constraint.",
                    field: "visualContract.interiorExterior"
                ))
            }

            let framedNames = Set(
                (contract.leftCharacters + contract.middleCharacters + contract.rightCharacters)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            let visibleNames = Set(
                contract.visibleCharacters
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            if !framedNames.isEmpty && !visibleNames.isSubset(of: framedNames) {
                blockers.append(.init(
                    code: .blockedVisualContractConflict,
                    message: "Shot card character list and left/middle/right blocking disagree.",
                    field: "visualContract.visibleCharacters"
                ))
            }
        }

        return blockers
    }
}

@available(macOS 26.0, *)
@MainActor
struct ReferenceContractResolver {
    var store: AnimateStore

    private enum SpatialContext: String {
        case unknown
        case insideTown = "inside_town"
        case outsideTown = "outside_town"
    }

    func resolve(spec: EffectiveShotSpec, projectRoot: URL, write: Bool = true) throws -> (contract: ReferenceContract, url: URL?) {
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let existing = readExisting(sceneID: spec.sceneID, shotID: spec.shotID, projectRoot: projectRoot)
        let rejectedKeys = Set((existing?.references ?? [])
            .filter { $0.status == .rejected }
            .map(referenceKey))
        var candidates: [ReferenceContractItem] = []
        candidates.append(contentsOf: (existing?.references ?? []).filter { $0.status == .pinned })
        candidates.append(contentsOf: storyboardReferences(spec: spec, projectRoot: projectRoot))
        candidates.append(contentsOf: generatedContinuityReferences(spec: spec, settings: shotSettings))
        candidates.append(contentsOf: placeReferences(spec: spec, projectRoot: projectRoot, settings: shotSettings))
        candidates.append(contentsOf: reviewedSemanticReferences(spec: spec, projectRoot: projectRoot, settings: shotSettings))
        candidates.append(contentsOf: registryReferences(spec: spec, projectRoot: projectRoot))
        candidates.append(contentsOf: characterReferences(spec: spec, projectRoot: projectRoot))
        // Style text is embedded directly in EffectiveShotSpec.prompt from
        // Settings/animated-look-prompt.json. Do not add that JSON file as an
        // image reference, or later paid phases could try to upload a non-image.
        candidates = deduplicated(candidates).filter { item in
            !rejectedKeys.contains(referenceKey(item))
                && isAllowedReference(item.path, settings: shotSettings)
                && (item.status == .pinned || !isFreeformCanvasReference(item))
        }
        if shotSettings.enforceSpatialContext {
            candidates = spatiallyCompatibleCandidates(candidates, spec: spec)
        }
        candidates = candidates.filter { !isForbiddenObjectReference($0, spec: spec) }
        if !candidates.contains(where: { $0.role == .locationIdentity }) {
            let adjacentFallback = adjacentLocationFallbackReferences(
                spec: spec,
                projectRoot: projectRoot,
                settings: shotSettings
            )
            candidates.append(contentsOf: adjacentFallback)
            candidates = deduplicated(candidates)
            candidates = candidates.filter { !isForbiddenObjectReference($0, spec: spec) }
        }
        var effectiveRoleQuotas = shotSettings.roleQuotas
        if !spec.characterSlugs.isEmpty {
            let currentQuota = effectiveRoleQuotas[.characterIdentity] ?? 0
            effectiveRoleQuotas[.characterIdentity] = max(currentQuota, spec.characterSlugs.count)
        }
        let selected = quotaLimited(
            candidates,
            maxReferences: shotSettings.maxReferenceCount,
            quotas: effectiveRoleQuotas
        )
        let rejectedAudit = (existing?.references ?? []).filter { $0.status == .rejected }
        var contract = ReferenceContract(
            sceneID: spec.sceneID,
            shotID: spec.shotID,
            shotIndex: spec.shotIndex,
            maxReferences: shotSettings.maxReferenceCount,
            roleQuotas: shotSettings.roleQuotas,
            references: deduplicated(selected + rejectedAudit),
            blockers: spec.blockers
        )
        if !contract.usableReferences.contains(where: { $0.role == .locationIdentity }) {
            contract.blockers.append(.init(code: .blockedMissingReferenceRole, message: "No location_identity reference resolved for this shot.", field: "references.location_identity"))
        }
        if shotSettings.requirePickedReferences,
           !contract.usableReferences.contains(where: { $0.status == .pinned || isPickedReference($0.path) }) {
            contract.blockers.append(.init(code: .blockedMissingReferenceRole, message: "No picked references are eligible for this shot. Add thumbs-up references before execute mode.", field: "references.picked_required"))
        }
        let url = write ? try writeContract(contract, projectRoot: projectRoot) : nil
        return (contract, url)
    }

    func contractURL(sceneID: UUID, shotID: UUID, projectRoot: URL) -> URL {
        AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "reference-contracts")
            .appendingPathComponent(sceneID.uuidString, isDirectory: true)
            .appendingPathComponent("\(shotID.uuidString).json")
    }

    func readExisting(sceneID: UUID, shotID: UUID, projectRoot: URL) -> ReferenceContract? {
        let url = contractURL(sceneID: sceneID, shotID: shotID, projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReferenceContract.self, from: data)
    }

    private func writeContract(_ contract: ReferenceContract, projectRoot: URL) throws -> URL {
        let url = contractURL(sceneID: contract.sceneID, shotID: contract.shotID, projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCodable(contract, to: url)
        return url
    }

    private func storyboardReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        let paths = ProjectPaths(root: projectRoot)
        return StoryboardFrame.allCases.compactMap { frame in
            let url = paths.shotStoryboardImage(sceneID: spec.sceneID, shotID: spec.shotID, frame: frame)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ReferenceContractItem(role: .storyboardLayout, path: url.path, label: "Storyboard \(frame.rawValue)", priority: 20, source: "same-shot storyboard")
        }
    }

    private func generatedContinuityReferences(spec: EffectiveShotSpec, settings: ShotGenerationSettings) -> [ReferenceContractItem] {
        guard let gallery = store.imagineGallery(for: spec.sceneID, shotIndex: spec.shotIndex) else { return [] }
        return ImagineShotMoment.allCases.flatMap { moment in
            gallery.paths(for: moment).compactMap { path in
                FileManager.default.fileExists(atPath: path) && isAllowedReference(path, settings: settings)
                    ? ReferenceContractItem(role: .shotContinuity, path: path, label: "Approved/generated \(moment.rawValue) frame", priority: 30, source: "same-shot generated frame")
                    : nil
            }
        }
    }

    private func placeReferences(spec: EffectiveShotSpec, projectRoot: URL, settings: ShotGenerationSettings) -> [ReferenceContractItem] {
        guard let id = spec.backgroundID,
              let bg = store.backgrounds.first(where: { $0.id == id }) else { return [] }
        var refs: [ReferenceContractItem] = []
        for path in [bg.approvedImagePath, bg.animatedApprovedImagePath].compactMap({ $0 }) {
            if let resolved = resolvedPath(path, projectRoot: projectRoot),
               isAllowedReference(resolved, settings: settings) {
                refs.append(.init(role: .locationIdentity, path: resolved, label: bg.name, priority: 40, source: "approved place image"))
            }
        }
        for ref in bg.referenceImages.prefix(3) {
            if let resolved = resolvedPath(ref.imagePath, projectRoot: projectRoot),
               isAllowedReference(resolved, settings: settings) {
                refs.append(.init(role: .locationIdentity, path: resolved, label: ref.title.isEmpty ? bg.name : ref.title, priority: 45, source: "place reference image", guidance: ref.notes))
            }
        }
        // Fallback: if explicit place references are missing/incomplete, source
        // rated non-rejected images from the place's on-disk asset folder.
        if refs.count < 2 {
            refs.append(contentsOf: fallbackPlaceLibraryReferences(for: bg, projectRoot: projectRoot))
        }
        return refs
    }

    private func reviewedSemanticReferences(
        spec: EffectiveShotSpec,
        projectRoot: URL,
        settings: ShotGenerationSettings
    ) -> [ReferenceContractItem] {
        let indexURL = projectRoot
            .appendingPathComponent("Metadata", isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("image-feedback", isDirectory: true)
            .appendingPathComponent("feedback-index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let shotText = joinedNonEmpty([
            spec.sceneName,
            spec.shotName,
            spec.action,
            spec.backgroundName,
            spec.lyricExcerpt,
            spec.notes,
            spec.cameraFraming,
            spec.cameraShot
        ], separator: "\n").lowercased()
        let queryTokens = keywordSet(from: shotText)
        guard !queryTokens.isEmpty else { return [] }
        let backgroundTokens = keywordSet(from: (spec.backgroundName ?? "").lowercased())
        let shotSpatialContext = classifyShotSpatialContext(spec: spec, shotText: shotText)

        var matches: [(score: Int, updatedAt: Date?, item: ReferenceContractItem)] = []
        for item in items {
            guard (item["isRejected"] as? Bool) != true,
                  (item["isLiked"] as? Bool) == true else { continue }

            let source = (item["source"] as? String)?.lowercased() ?? ""
            let semanticRole = (item["semanticRole"] as? String)?.lowercased() ?? ""
            if semanticRole == "character" { continue }
            if source == "characters" { continue }

            let relativePath = (item["projectRelativePath"] as? String) ?? ""
            let group = (item["groupLabel"] as? String) ?? ""
            if isCanvasSemanticReference(
                source: source,
                group: group,
                relativePath: relativePath,
                semanticRole: semanticRole
            ) {
                continue
            }

            let resolvedImagePath: String? = {
                if let relative = item["projectRelativePath"] as? String {
                    return resolvedPath(relative, projectRoot: projectRoot)
                }
                if let absolute = item["imagePath"] as? String {
                    return resolvedPath(absolute, projectRoot: projectRoot)
                }
                return nil
            }()
            guard let path = resolvedImagePath,
                  FileManager.default.fileExists(atPath: path),
                  isAllowedReference(path, settings: settings) else { continue }

            let analysis = item["analysis"] as? [String: Any] ?? [:]
            let filenameHints = URL(fileURLWithPath: path)
                .lastPathComponent
                .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: " ", options: .regularExpression)
            let summary = (analysis["summary"] as? String) ?? ""
            let shortCaption = (analysis["shortCaption"] as? String) ?? ""
            let retrieval = (analysis["retrievalJSON"] as? String) ?? ""
            let entities = (analysis["entitiesJSON"] as? String) ?? ""
            let scene = (analysis["sceneJSON"] as? String) ?? ""
            let camera = (analysis["cameraJSON"] as? String) ?? ""
            let notes = (item["notes"] as? String) ?? ""
            let origin = (item["originLabel"] as? String) ?? ""
            let role = semanticRole
            let sourceText = source
            let candidateText = joinedNonEmpty([
                summary,
                shortCaption,
                retrieval,
                entities,
                scene,
                camera,
                filenameHints,
                relativePath,
                path,
                notes,
                origin,
                group,
                role,
                sourceText
            ], separator: "\n").lowercased()
            if candidateText.isEmpty { continue }
            let shotLower = shotText.lowercased()
            if isVehicleInteriorReferenceText(candidateText),
               !isVehicleInteriorShotText(shotLower) {
                continue
            }
            let candidateSpatialContext = classifyReferenceSpatialContext(
                candidateText: candidateText,
                path: path
            )
            if settings.enforceSpatialContext,
               shotSpatialContext != .unknown,
               candidateSpatialContext != .unknown,
               shotSpatialContext != candidateSpatialContext {
                continue
            }
            if containsAny(candidateText, terms: ["bridge", "crossing", "span"]),
               !containsAny(shotLower, terms: ["bridge", "crossing", "span"]) {
                continue
            }
            if containsAny(candidateText, terms: ["outpost", "encampment", "camp", "tent", "tower", "sniper", "base"]),
               !containsAny(shotLower, terms: ["outpost", "encampment", "camp", "tent", "tower", "sniper", "base"]) {
                continue
            }
            if containsAny(candidateText, terms: ["alley", "stair", "stairs", "laundry", "pottery", "corridor", "market"]),
               !containsAny(shotLower, terms: ["alley", "stair", "stairs", "laundry", "pottery", "corridor", "market"]) {
                continue
            }
            if containsAny(candidateText, terms: ["clinic", "hospital"]),
               !containsAny(shotLower, terms: ["clinic", "hospital", "medical tent", "field hospital"]) {
                continue
            }
            let candidateTokens = keywordSet(from: candidateText)
            if !backgroundTokens.isEmpty && backgroundTokens.intersection(candidateTokens).isEmpty {
                continue
            }

            let score = semanticMatchScore(
                queryText: shotText,
                queryTokens: queryTokens,
                candidateText: candidateText
            )
            if score < 10 { continue }

            let updatedAt = (item["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let label = firstNonEmpty(summary, shortCaption, origin, group, spec.backgroundName) ?? "liked semantic reference"
            let spatialGuidance: String? = {
                switch candidateSpatialContext {
                case .insideTown: return "Spatial context: inside_town"
                case .outsideTown: return "Spatial context: outside_town"
                case .unknown: return nil
                }
            }()
            let guidance = joinedNonEmpty([spatialGuidance, firstNonEmpty(shortCaption, summary, notes)], separator: " | ")
            matches.append((
                score: score,
                updatedAt: updatedAt,
                item: .init(
                    role: .locationIdentity,
                    path: path,
                    label: label,
                    priority: 35,
                    source: "image-feedback semantic match",
                    guidance: guidance.isEmpty ? nil : guidance
                )
            ))
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.updatedAt != rhs.updatedAt {
                    return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
                }
                return lhs.item.path < rhs.item.path
            }
            .prefix(8)
            .map(\.item)
    }

    private func isCanvasSemanticReference(
        source: String,
        group: String,
        relativePath: String,
        semanticRole: String
    ) -> Bool {
        let normalizedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRelativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCanvasPool = source == "canvas"
            || normalizedGroup == "canvas"
            || normalizedRelativePath.hasPrefix("canvas/")
        guard isCanvasPool else { return false }

        // The freeform Canvas pool contains experiments, rejects, and old
        // generations. Shot generation should use curated place/shot reference
        // slots instead of promoting Canvas feedback items to location identity.
        _ = semanticRole
        return true
    }

    private func isFreeformCanvasReference(_ item: ReferenceContractItem) -> Bool {
        let source = item.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = item.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source.contains("canvas")
            || path.contains("/canvas/")
            || path.contains("/animate/canvas/")
    }

    private func fallbackPlaceLibraryReferences(
        for background: BackgroundPlate,
        projectRoot: URL
    ) -> [ReferenceContractItem] {
        let fm = FileManager.default
        let placesRoot = projectRoot
            .appendingPathComponent("Animate", isDirectory: true)
            .appendingPathComponent("backgrounds", isDirectory: true)
            .appendingPathComponent("places", isDirectory: true)
        guard fm.fileExists(atPath: placesRoot.path) else { return [] }

        let slugs = [
            slugify(background.filename),
            slugify(background.name)
        ]
        .filter { !$0.isEmpty }

        var candidateDirectories: [URL] = []
        for slug in slugs {
            let direct = placesRoot.appendingPathComponent(slug, isDirectory: true)
            if fm.fileExists(atPath: direct.path) {
                candidateDirectories.append(direct)
            }
        }

        if candidateDirectories.isEmpty, let primarySlug = slugs.first {
            if let enumerator = fm.enumerator(
                at: placesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let name = url.lastPathComponent.lowercased()
                    if name.contains(primarySlug) || primarySlug.contains(name) {
                        candidateDirectories.append(url)
                    }
                }
            }
        }

        guard !candidateDirectories.isEmpty else { return [] }

        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        var discoveredPaths = Set<String>()
        for directory in candidateDirectories {
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                discoveredPaths.insert(url.standardizedFileURL.path)
            }
        }

        let ranked = discoveredPaths.compactMap { path -> (path: String, updatedAt: Date)? in
            guard isPickedReference(path),
                  let metadata = referenceMetadata(path),
                  metadata.isRejected == false else {
                return nil
            }
            return (path: path, updatedAt: metadata.updatedAt ?? .distantPast)
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }

        return ranked.prefix(3).map { candidate in
            ReferenceContractItem(
                role: .locationIdentity,
                path: candidate.path,
                label: background.name,
                priority: 47,
                source: "place library fallback"
            )
        }
    }

    private func slugify(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func registryReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        let url = ProjectPaths(root: projectRoot).animate.appendingPathComponent("reference-registry.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backgrounds = object["backgrounds"] as? [[String: Any]] else { return [] }
        let text = [spec.shotName, spec.action, spec.backgroundName ?? "", spec.regionalWorldCues, spec.architectureMaterials].joined(separator: " ").lowercased()
        let wantsMap = text.contains("outdoor") || text.contains("valley") || text.contains("road") || text.contains("river") || text.contains("bridge") || text.contains("geography") || text.contains("ridge")
        let wantsBridge = text.contains("bridge") || (spec.backgroundName?.lowercased().contains("bridge") ?? false)
        var refs: [ReferenceContractItem] = []
        for entry in backgrounds {
            let name = (entry["name"] as? String ?? "").lowercased()
            guard (name == "map" && wantsMap) || (name == "bridge" && wantsBridge) else { continue }
            let role: ReferenceRole = name == "map" ? .spatialMap : .landmarkDesign
            let priority = name == "map" ? 50 : 55
            let guidance = entry["guidance"] as? String
            for file in (entry["files"] as? [[String: Any]] ?? []) {
                if let path = file["absolute_path"] as? String, FileManager.default.fileExists(atPath: path) {
                    refs.append(.init(role: role, path: path, label: "registry \(name)", priority: priority, source: "reference-registry.json", guidance: guidance))
                }
            }
        }
        return refs
    }

    private func characterReferences(spec: EffectiveShotSpec, projectRoot: URL) -> [ReferenceContractItem] {
        let wanted = Set((spec.characterSlugs + [spec.focusCharacterSlug].compactMap { $0 }).map { $0.lowercased() })
        guard !wanted.isEmpty else { return [] }
        let closeUpShot = isCloseUpCharacterShot(spec: spec)
        var refs: [ReferenceContractItem] = []
        for character in store.characters where wanted.contains(characterSlug(character).lowercased()) || wanted.contains(character.owpSlug.lowercased()) {
            if let costumeReference = selectedCharacterCostumeReference(
                for: character,
                spec: spec,
                projectRoot: projectRoot
            ) {
                refs.append(costumeReference)
            }
            if closeUpShot,
               let headReference = selectedCharacterHeadReference(
                   for: character,
                   spec: spec,
                   projectRoot: projectRoot
               ) {
                refs.append(headReference)
            }
        }
        return deduplicated(refs)
    }

    private func styleReferences(projectRoot: URL) -> [ReferenceContractItem] {
        let url = ProjectPaths(root: projectRoot).animatedLookPromptJSON
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return [.init(role: .style, path: url.path, label: "Animated look prompt", priority: 90, source: "Settings/animated-look-prompt.json")]
    }

    private func selectedCharacterCostumeReference(
        for character: AnimationCharacter,
        spec: EffectiveShotSpec,
        projectRoot: URL
    ) -> ReferenceContractItem? {
        let desiredWardrobe = preferredWardrobe(for: character, spec: spec)
        let desiredFraming: CharacterShotReferenceFraming = isCloseUpCharacterShot(spec: spec) ? .closeUp : .fullBody
        let desiredView = preferredCharacterReferenceView(spec: spec)

        let resolvedReferences: [(reference: CharacterShotReferenceImage, path: String)] = character.shotReferenceImages.compactMap { reference in
            guard let resolved = resolvedPath(reference.imagePath, projectRoot: projectRoot),
                  FileManager.default.fileExists(atPath: resolved),
                  referenceMetadata(resolved)?.isRejected != true else { return nil }
            return (reference: reference, path: resolved)
        }
        guard !resolvedReferences.isEmpty else { return nil }

        let wardrobePool = resolvedReferences.filter { $0.reference.wardrobe == desiredWardrobe }
        guard !wardrobePool.isEmpty else { return nil }

        let framingPoolSource = wardrobePool
        let framingPool = framingPoolSource.filter { $0.reference.framing == desiredFraming }
        let viewPoolSource = framingPool.isEmpty ? framingPoolSource : framingPool
        let viewPool = viewPoolSource.filter { $0.reference.view == desiredView }
        let finalPool = viewPool.isEmpty ? viewPoolSource : viewPool

        let selected = finalPool.sorted { lhs, rhs in
            let lhsMeta = referenceMetadata(lhs.path)
            let rhsMeta = referenceMetadata(rhs.path)
            if (lhsMeta?.isLiked ?? false) != (rhsMeta?.isLiked ?? false) {
                return (lhsMeta?.isLiked ?? false) && !(rhsMeta?.isLiked ?? false)
            }
            if lhs.reference.framing != rhs.reference.framing {
                if lhs.reference.framing == desiredFraming { return true }
                if rhs.reference.framing == desiredFraming { return false }
            }
            if lhs.reference.view != rhs.reference.view {
                if lhs.reference.view == desiredView { return true }
                if rhs.reference.view == desiredView { return false }
            }
            if lhsMeta?.updatedAt != rhsMeta?.updatedAt {
                return (lhsMeta?.updatedAt ?? .distantPast) > (rhsMeta?.updatedAt ?? .distantPast)
            }
            return lhs.path < rhs.path
        }.first

        guard let selected else { return nil }
        let sourceLabel = [
            selected.reference.framing.displayName,
            selected.reference.wardrobe.displayName,
            selected.reference.view.displayName
        ].joined(separator: " / ")
        return .init(
            role: .characterIdentity,
            path: selected.path,
            label: "\(character.name) \(sourceLabel)",
            priority: 60,
            source: "character shot reference images"
        )
    }

    private func selectedCharacterHeadReference(
        for character: AnimationCharacter,
        spec: EffectiveShotSpec,
        projectRoot: URL
    ) -> ReferenceContractItem? {
        let preferredPose = preferredHeadPose(spec: spec)
        var poseOrder: [CharacterReferencePose] = [
            preferredPose,
            .frontNeutral,
            .quarterLeft,
            .quarterRight,
            .leftProfile,
            .rightProfile,
            .back
        ]
        var seen = Set<String>()
        poseOrder = poseOrder.filter { seen.insert($0.rawValue).inserted }

        for pose in poseOrder {
            guard let slot = character.headTurnaroundSlots.first(where: { $0.pose == pose }),
                  let variantPath = slot.approvedVariant?.imagePath,
                  let resolved = resolvedPath(variantPath, projectRoot: projectRoot),
                  FileManager.default.fileExists(atPath: resolved),
                  referenceMetadata(resolved)?.isRejected != true else { continue }
            return .init(
                role: .characterIdentity,
                path: resolved,
                label: "\(character.name) Head \(slot.title)",
                priority: 58,
                source: "character head turnaround slot"
            )
        }

        if let headSheetPath = character.approvedHeadTurnaroundSheetVariant?.imagePath,
           let resolved = resolvedPath(headSheetPath, projectRoot: projectRoot),
           FileManager.default.fileExists(atPath: resolved),
           referenceMetadata(resolved)?.isRejected != true {
            return .init(
                role: .characterIdentity,
                path: resolved,
                label: "\(character.name) Head Turnaround Sheet",
                priority: 59,
                source: "character head turnaround sheet"
            )
        }
        return nil
    }

    private func quotaLimited(_ candidates: [ReferenceContractItem], maxReferences: Int, quotas: [ReferenceRole: Int]) -> [ReferenceContractItem] {
        var selected: [ReferenceContractItem] = []
        var counts: [ReferenceRole: Int] = [:]
        for item in candidates.sorted(by: { lhs, rhs in
            if lhs.status == .pinned && rhs.status != .pinned { return true }
            if lhs.status != .pinned && rhs.status == .pinned { return false }
            let lhsMeta = referenceMetadata(lhs.path)
            let rhsMeta = referenceMetadata(rhs.path)
            if (lhsMeta?.isLiked ?? false) != (rhsMeta?.isLiked ?? false) {
                return (lhsMeta?.isLiked ?? false) && !(rhsMeta?.isLiked ?? false)
            }
            if lhsMeta?.updatedAt != rhsMeta?.updatedAt {
                return (lhsMeta?.updatedAt ?? .distantPast) > (rhsMeta?.updatedAt ?? .distantPast)
            }
            return lhs.priority < rhs.priority
        }) {
            if selected.count >= maxReferences { break }
            let quota = quotas[item.role] ?? 1
            if item.status != .pinned && (counts[item.role] ?? 0) >= quota { continue }
            selected.append(item)
            counts[item.role, default: 0] += 1
        }
        return selected
    }

    private func deduplicated(_ items: [ReferenceContractItem]) -> [ReferenceContractItem] {
        var seen = Set<String>()
        return items.filter { seen.insert(referenceKey($0)).inserted }
    }

    private func referenceKey(_ item: ReferenceContractItem) -> String { "\(item.role.rawValue)|\(item.path)" }

    private func isAllowedReference(
        _ path: String,
        settings: ShotGenerationSettings
    ) -> Bool {
        if AnimateStore.isGeographyTaintedReferencePath(path) {
            return false
        }

        if store.generatedBackgroundRecord(for: path)?.isRejected == true {
            return false
        }

        let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)

        if settings.dropRejectedReferences, metadata?.isRejected == true {
            return false
        }

        if settings.requirePickedReferences {
            return metadata?.isLiked == true
        }

        let requireRated = settings.requireRatedReferences
        let minRating = min(max(settings.minimumReferenceRating, requireRated ? 1 : 0), 5)
        guard requireRated || minRating > 0 else {
            return true
        }

        guard let rating = metadata?.rating else {
            return false
        }
        return min(max(rating, 1), 5) >= minRating
    }

    private func referenceRating(_ path: String) -> Int? {
        guard let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path),
              metadata.isRejected == false,
              let rating = metadata.rating,
              rating > 0 else { return nil }
        return min(max(rating, 1), 5)
    }

    private func referenceMetadata(_ path: String) -> ImageLibraryReviewMetadata? {
        ImageLibraryMetadataSidecarService.load(forImagePath: path)
    }

    private func isPickedReference(_ path: String) -> Bool {
        ImageLibraryMetadataSidecarService.load(forImagePath: path)?.isLiked == true
    }

    private func isVehicleInteriorReferenceText(_ text: String) -> Bool {
        containsAny(
            text.lowercased(),
            terms: [
                "vehicle interior",
                "humvee interior",
                "military vehicle interior",
                "inside a military vehicle",
                "inside the military vehicle",
                "inside a vehicle",
                "inside the vehicle",
                "inside a humvee",
                "inside the humvee",
                "looking into the cabin",
                "looking out from inside",
                "through the windshield",
                "dashboard",
                "windshield",
                "seat backs",
                "back seats",
                "front seats"
            ]
        )
    }

    private func isVehicleInteriorShotText(_ text: String) -> Bool {
        containsAny(
            text.lowercased(),
            terms: [
                "vehicle interior",
                "humvee interior",
                "military vehicle interior",
                "inside a military vehicle",
                "inside the military vehicle",
                "inside a vehicle",
                "inside the vehicle",
                "inside a humvee",
                "inside the humvee",
                "inside the cabin",
                "in the cabin",
                "cabin interior",
                "dashboard",
                "windshield",
                "seated inside",
                "seated in the vehicle",
                "seated in the humvee",
                "from inside the vehicle",
                "from inside the humvee",
                "through the windshield"
            ]
        )
    }

    private func spatiallyCompatibleCandidates(
        _ candidates: [ReferenceContractItem],
        spec: EffectiveShotSpec
    ) -> [ReferenceContractItem] {
        let shotContext = classifyShotSpatialContext(spec: spec, shotText: shotSelectionText(spec: spec))
        guard shotContext != .unknown else { return candidates }
        let shotText = shotSelectionText(spec: spec)
        return candidates.filter { item in
            if item.status == .pinned { return true }
            switch item.role {
            case .locationIdentity, .landmarkDesign, .spatialMap:
                let candidateText = candidateSpatialContextText(for: item)
                if isVehicleInteriorReferenceText(candidateText),
                   !isVehicleInteriorShotText(shotText) {
                    return false
                }
                let candidateContext = classifyReferenceSpatialContext(
                    candidateText: candidateText,
                    path: item.path
                )
                if candidateContext == .unknown { return true }
                return candidateContext == shotContext
            default:
                return true
            }
        }
    }

    private func adjacentLocationFallbackReferences(
        spec: EffectiveShotSpec,
        projectRoot: URL,
        settings: ShotGenerationSettings
    ) -> [ReferenceContractItem] {
        guard let scene = store.scenes.first(where: { $0.id == spec.sceneID }) else { return [] }
        let adjacentIndices = [spec.shotIndex - 1, spec.shotIndex + 1].filter { $0 >= 0 && $0 < scene.shots.count }
        guard !adjacentIndices.isEmpty else { return [] }

        var fallback: [ReferenceContractItem] = []
        for index in adjacentIndices {
            let adjacentShotID = scene.shots[index].id
            guard let adjacentContract = readExisting(
                sceneID: spec.sceneID,
                shotID: adjacentShotID,
                projectRoot: projectRoot
            ) else { continue }
            for ref in adjacentContract.usableReferences where ref.role == .locationIdentity {
                guard FileManager.default.fileExists(atPath: ref.path),
                      isAllowedReference(ref.path, settings: settings) else { continue }
                if ref.source.lowercased().contains("image-feedback semantic match"),
                   ref.path.lowercased().contains("/canvas/") {
                    continue
                }
                fallback.append(
                    .init(
                        role: ref.role,
                        path: ref.path,
                        label: ref.label,
                        priority: min(ref.priority + 6, 90),
                        source: "\(ref.source) (adjacent shot \(index + 1))",
                        guidance: ref.guidance
                    )
                )
            }
        }

        if settings.enforceSpatialContext {
            fallback = spatiallyCompatibleCandidates(fallback, spec: spec)
        }
        return deduplicated(fallback)
    }

    private func candidateSpatialContextText(for item: ReferenceContractItem) -> String {
        let metadata = referenceMetadata(item.path)
        return joinedNonEmpty([
            item.label,
            item.source,
            item.guidance,
            item.path,
            metadata?.notes,
            metadata?.semanticRole?.rawValue
        ], separator: "\n").lowercased()
    }

    private func shotSelectionText(spec: EffectiveShotSpec) -> String {
        joinedNonEmpty([
            spec.sceneName,
            spec.shotName,
            spec.action,
            spec.lyricExcerpt,
            spec.notes,
            spec.cameraFraming,
            spec.cameraShot
        ], separator: "\n").lowercased()
    }

    private func shotObjectText(spec: EffectiveShotSpec) -> String {
        joinedNonEmpty([
            shotSelectionText(spec: spec),
            spec.backgroundName,
            spec.shotCardPlaces?.joined(separator: " "),
            spec.shotCardProps?.joined(separator: " "),
            spec.shotCardLandmarks?.joined(separator: " "),
            spec.shotCardNotes,
            spec.shotCardContinuityNotes
        ], separator: "\n").lowercased()
    }

    private func isForbiddenObjectReference(_ item: ReferenceContractItem, spec: EffectiveShotSpec) -> Bool {
        let candidateText = candidateSpatialContextText(for: item)
        let shotText = shotObjectText(spec: spec)
        if isHumveeReferenceText(candidateText),
           !isHumveeShotText(shotText) {
            AppLog.log(
                "IMAGE_INTELLIGENCE",
                "Excluded automatic reference '\(URL(fileURLWithPath: item.path).lastPathComponent)' from \(spec.sceneName) S\(spec.shotIndex + 1): forbidden Humvee/vehicle context."
            )
            return true
        }
        return false
    }

    private func isHumveeReferenceText(_ text: String) -> Bool {
        containsAny(
            text.lowercased(),
            terms: [
                "humvee",
                "hmmwv",
                "military vehicle",
                "vehicle interior",
                "convoy vehicle",
                "inside the vehicle",
                "inside a vehicle",
                "windshield",
                "dashboard"
            ]
        )
    }

    private func isHumveeShotText(_ text: String) -> Bool {
        containsAny(
            text.lowercased(),
            terms: [
                "humvee",
                "hmmwv",
                "military vehicle",
                "vehicle interior",
                "convoy",
                "inside the vehicle",
                "inside a vehicle",
                "inside the cabin",
                "truck",
                "trucks",
                "driver",
                "passenger seat",
                "windshield",
                "dashboard"
            ]
        )
    }

    private func isActOneScene(_ sceneName: String) -> Bool {
        let normalized = sceneName.lowercased()
        return normalized.hasPrefix("1.") || normalized.contains("act i") || normalized.contains("overture")
    }

    private func preferredWardrobe(for character: AnimationCharacter, spec: EffectiveShotSpec) -> CharacterShotReferenceWardrobe {
        let shotText = shotSelectionText(spec: spec)
        let slug = characterSlug(character).lowercased()
        if (slug.contains("luke") || character.owpSlug.lowercased() == "luke"),
           isActOneScene(spec.sceneName) {
            return .soldier
        }

        let militaryTerms = [
            "soldier", "uniform", "medic", "convoy", "humvee", "military",
            "tactical", "vest", "helmet", "rifle", "radio", "driver", "passenger",
            "back row", "notebook and medic-cross patch"
        ]
        if containsAny(shotText, terms: militaryTerms) {
            return .soldier
        }

        let civilianTerms = [
            "civilian", "plain clothes", "local outfit", "modest", "community leader",
            "teacher", "mother", "home", "market day", "family"
        ]
        if containsAny(shotText, terms: civilianTerms) {
            return .civilian
        }

        switch character.defaultWardrobeType {
        case .civilian: return .civilian
        case .soldier: return .soldier
        }
    }

    private func preferredCharacterReferenceView(spec: EffectiveShotSpec) -> CharacterShotReferenceView {
        let text = shotSelectionText(spec: spec)
        let backViewTerms = ["back view", "rear view", "from behind", "facing away", "back-facing", "back of character", "turned away"]
        return containsAny(text, terms: backViewTerms) ? .back : .front
    }

    private func isCloseUpCharacterShot(spec: EffectiveShotSpec) -> Bool {
        if let cameraShotRaw = spec.cameraShot?.lowercased(),
           ["medium_close", "close", "extreme_close"].contains(cameraShotRaw) {
            return true
        }
        let text = shotSelectionText(spec: spec)
        let closeUpTerms = ["close-up", "close up", "portrait", "head shot", "face close", "facial close", "profile close"]
        return containsAny(text, terms: closeUpTerms)
    }

    private func preferredHeadPose(spec: EffectiveShotSpec) -> CharacterReferencePose {
        let text = shotSelectionText(spec: spec)
        if containsAny(text, terms: ["back of head", "back view", "rear view", "from behind", "facing away"]) {
            return .back
        }
        if containsAny(text, terms: ["left profile", "profile left", "facing left"]) {
            return .leftProfile
        }
        if containsAny(text, terms: ["right profile", "profile right", "facing right"]) {
            return .rightProfile
        }
        if containsAny(text, terms: ["quarter left", "three-quarter left", "3/4 left"]) {
            return .quarterLeft
        }
        if containsAny(text, terms: ["quarter right", "three-quarter right", "3/4 right"]) {
            return .quarterRight
        }
        return .frontNeutral
    }

    private func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains(where: { text.contains($0) })
    }

    private func countMatches(_ text: String, terms: [String]) -> Int {
        terms.reduce(into: 0) { partialResult, term in
            if text.contains(term) { partialResult += 1 }
        }
    }

    private func classifyShotSpatialContext(spec: EffectiveShotSpec, shotText: String) -> SpatialContext {
        let text = joinedNonEmpty([
            shotText,
            spec.regionalWorldCues,
            spec.architectureMaterials,
            spec.backgroundName
        ], separator: "\n").lowercased()
        let insideTerms = [
            "inside town", "town street", "market", "marketplace", "alley", "lane",
            "corridor", "bazaar", "courtyard", "shopfront", "inside village",
            "clinic", "hospital", "residential", "doorway"
        ]
        let outsideTerms = [
            "outside town", "valley", "mountain", "ridge", "river", "bridge",
            "road", "convoy", "humvee", "outpost", "hillside", "desert", "trail",
            "overlook", "pass", "canyon"
        ]
        let insideScore = countMatches(text, terms: insideTerms)
        let outsideScore = countMatches(text, terms: outsideTerms)
        if outsideScore >= insideScore + 1 { return .outsideTown }
        if insideScore >= outsideScore + 1 { return .insideTown }
        return .unknown
    }

    private func classifyReferenceSpatialContext(candidateText: String, path: String) -> SpatialContext {
        let pathHints = path
            .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: " ", options: .regularExpression)
            .lowercased()
        let text = joinedNonEmpty([candidateText, pathHints], separator: "\n").lowercased()
        if containsAny(text, terms: ["clinic", "hospital", "market", "alley", "bazaar", "town street", "village street"]),
           !containsAny(text, terms: ["convoy", "humvee", "outpost", "encampment", "ridge overlook"]) {
            return .insideTown
        }
        let insideTerms = [
            "market", "marketplace", "alley", "street", "lane", "corridor",
            "courtyard", "shop", "shopfront", "bazaar", "inside town", "inside village",
            "awning", "pottery", "laundry", "clinic", "hospital", "residential", "doorway"
        ]
        let outsideTerms = [
            "valley", "mountain", "ridge", "river", "bridge", "trail",
            "convoy", "humvee", "vehicle", "outpost", "encampment", "camp",
            "desert", "hillside", "pass", "canyon", "overlook"
        ]
        let insideScore = countMatches(text, terms: insideTerms)
        let outsideScore = countMatches(text, terms: outsideTerms)
        if outsideScore >= insideScore + 1 { return .outsideTown }
        if insideScore >= outsideScore + 1 { return .insideTown }
        return .unknown
    }

    private func keywordSet(from text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "that", "this", "into", "over",
            "under", "through", "shot", "scene", "frame", "style", "look", "keep",
            "only", "then", "than", "have", "has", "was", "are", "not", "but"
        ]
        return Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 4 && !stopwords.contains($0) }
        )
    }

    private func semanticMatchScore(
        queryText: String,
        queryTokens: Set<String>,
        candidateText: String
    ) -> Int {
        let queryLower = queryText.lowercased()
        let candidateLower = candidateText.lowercased()
        let candidateTokens = keywordSet(from: candidateLower)

        var score = queryTokens.intersection(candidateTokens).count * 2

        func applyFacetScore(
            terms: [String],
            matchBonus: Int,
            missPenalty: Int,
            offTopicPenalty: Int = 0
        ) {
            let queryHasFacet = terms.contains(where: { queryLower.contains($0) || queryTokens.contains($0) })
            let candidateHasFacet = terms.contains(where: { candidateLower.contains($0) || candidateTokens.contains($0) })
            if queryHasFacet {
                score += candidateHasFacet ? matchBonus : missPenalty
            } else if candidateHasFacet, offTopicPenalty != 0 {
                score += offTopicPenalty
            }
        }

        applyFacetScore(
            terms: ["valley", "mountain", "ridge", "river", "road", "terrain", "landscape"],
            matchBonus: 3,
            missPenalty: -2
        )
        applyFacetScore(
            terms: ["extreme wide", "wide", "establishing", "panorama", "overlook", "aerial"],
            matchBonus: 3,
            missPenalty: -1,
            offTopicPenalty: -2
        )
        applyFacetScore(
            terms: ["humvee", "convoy", "vehicle", "truck", "wheels", "driving"],
            matchBonus: 4,
            missPenalty: -4
        )
        applyFacetScore(
            terms: ["convoy", "column", "formation", "caravan"],
            matchBonus: 5,
            missPenalty: -5
        )
        applyFacetScore(
            terms: ["interior", "cabin", "dashboard", "seat", "windshield", "window", "cockpit"],
            matchBonus: 4,
            missPenalty: -3
        )
        applyFacetScore(
            terms: ["back row", "driver", "passenger", "inside", "cabin"],
            matchBonus: 5,
            missPenalty: -6
        )
        applyFacetScore(
            terms: ["bridge", "crossing", "span"],
            matchBonus: 3,
            missPenalty: -2,
            offTopicPenalty: -2
        )
        applyFacetScore(
            terms: ["village", "alley", "stair", "stairs", "laundry", "pottery", "corridor", "market"],
            matchBonus: 2,
            missPenalty: -2,
            offTopicPenalty: -3
        )
        applyFacetScore(
            terms: ["clinic", "hospital", "medical ward", "field hospital"],
            matchBonus: 2,
            missPenalty: -2,
            offTopicPenalty: -4
        )
        applyFacetScore(
            terms: ["outpost", "encampment", "camp", "tent", "tower", "sniper", "fortification", "base"],
            matchBonus: 3,
            missPenalty: -2,
            offTopicPenalty: -4
        )

        return max(score, 0)
    }
}

@available(macOS 26.0, *)
@MainActor
struct ShotFramePlanBuilder {
    var store: AnimateStore

    func buildPlans(spec: EffectiveShotSpec, contract: ReferenceContract, projectRoot: URL, imageSize: String) -> ShotFrameGenerationPlanSet {
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let resolvedImageSize = imageSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? shotSettings.generatedImageSize
            : imageSize.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = contract.usableReferences
            .filter { $0.role != .style }
            .map(\.path)
        let gallery = store.imagineGallery(for: spec.sceneID, shotIndex: spec.shotIndex)
        let previousGallery = spec.shotIndex > 0 ? store.imagineGallery(for: spec.sceneID, shotIndex: spec.shotIndex - 1) : nil
        let cameraShot = spec.cameraShot.flatMap(CameraShot.init(rawValue:))
        let plans = ImagineShotMoment.allCases.map { moment in
            ShotFrameGenerationPlanResolver.resolve(
                input: .init(
                    projectRoot: projectRoot,
                    sceneID: spec.sceneID,
                    shotID: spec.shotID,
                    shotIndex: spec.shotIndex,
                    moment: moment,
                    prompt: spec.prompt,
                    gallery: gallery,
                    previousShotGallery: previousGallery,
                    automaticReferenceImagePaths: references,
                    manualReferenceCount: contract.usableReferences.filter { $0.status == .pinned }.count,
                    cameraShot: cameraShot,
                    cameraMovement: nil,
                    generatedAspectRatio: shotSettings.generatedAspectRatio,
                    generatedImageSize: resolvedImageSize,
                    extractionTargetAspectRatio: shotSettings.extractionTargetAspectRatio,
                    finalDeliveryAspectRatio: shotSettings.finalDeliveryAspectRatio,
                    requirePickedReferences: shotSettings.requirePickedReferences,
                    requireRatedReferences: shotSettings.requireRatedReferences,
                    minimumReferenceRating: shotSettings.minimumReferenceRating,
                    includeOpenMatteCropContractText: shotSettings.includeOpenMatteCropContractText,
                    forbidVisibleFrameGuides: shotSettings.forbidVisibleFrameGuides
                )
            )
        }
        return ShotFrameGenerationPlanSet(sceneID: spec.sceneID, shotID: spec.shotID, plans: plans)
    }

    func write(_ planSet: ShotFrameGenerationPlanSet, projectRoot: URL) throws -> URL {
        let dir = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-frame-plans")
            .appendingPathComponent(planSet.sceneID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(planSet.shotID.uuidString).json")
        try writeCodable(planSet, to: url)
        return url
    }
}

@available(macOS 26.0, *)
struct AutomationDryRunShotResult: Codable, Sendable, Hashable {
    var effectiveShotSpec: EffectiveShotSpec
    var effectiveShotSpecPath: String?
    var referenceContract: ReferenceContract
    var referenceContractPath: String?
    var shotFrameGenerationPlanSet: ShotFrameGenerationPlanSet
    var shotFrameGenerationPlanPath: String?
    var estimatedVertexCostUSD: Double
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
struct AutomationDryRunReport: Codable, Sendable, Hashable {
    var schemaVersion: Int = 1
    var generatedAt: Date = Date()
    var mode: String = "dry_run"
    var model: String
    var imageSize: String
    var projectSummary: AutomationProjectSummary
    var shots: [AutomationDryRunShotResult]
    var estimatedVertexCostUSD: Double
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
func characterSlug(_ character: AnimationCharacter) -> String {
    (character.storageSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? character.storageSlug : nil) ?? character.owpSlug
}

@available(macOS 26.0, *)
func resolvedPath(_ raw: String?, projectRoot: URL) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw.hasPrefix("/") { return FileManager.default.fileExists(atPath: raw) ? raw : raw }
    return projectRoot.appendingPathComponent(raw).path
}

@available(macOS 26.0, *)
func firstNonEmpty(_ values: String?...) -> String? {
    values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
}

@available(macOS 26.0, *)
func joinedNonEmpty(_ values: [String?], separator: String) -> String {
    values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: separator)
}

@available(macOS 26.0, *)
func firstLine(of value: String?) -> String? {
    guard let value else { return nil }
    return value
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

@available(macOS 26.0, *)
func currentImageGenerationProviderLabel() -> String {
    switch ImageGenBackendStore.currentBackend() {
    case .vertex: return "vertex"
    case .aiStudio: return "gemini"
    }
}

@available(macOS 26.0, *)
func animatedLookPrompt(projectRoot: URL) -> String? {
    let url = ProjectPaths(root: projectRoot).animatedLookPromptJSON
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["prompt"] as? String
}

@available(macOS 26.0, *)
func writeCodable<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

@available(macOS 26.0, *)
struct AutomationFrameGenerationRunResponse: Codable, Sendable, Hashable {
    var schemaVersion: Int = 1
    var generatedAt: Date = Date()
    var ok: Bool
    var mode: String
    var isDryRun: Bool
    var model: String
    var imageSize: String
    var estimatedCostUSD: Double
    var maxCostUSD: Double?
    var records: [GeneratedFrameRecord]
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
@MainActor
struct AutomationFrameGenerationService {
    var store: AnimateStore

    func run(
        projectRoot: URL,
        sceneFilter: Set<UUID>?,
        shotFilter: UUID?,
        moments requestedMoments: [ImagineShotMoment],
        model: GeminiModel,
        imageSize: String,
        mode: String,
        maxCostUSD: Double?,
        maxFrames: Int?,
        useLLMPromptCompiler overrideUseLLMPromptCompiler: Bool? = nil
    ) async -> AutomationFrameGenerationRunResponse {
        let isExecute = mode == "execute"
        let isDryRun = !isExecute
        var records: [GeneratedFrameRecord] = []
        var blockers: [AutomationBlocker] = []
        let moments = requestedMoments.isEmpty ? [.beginning] : requestedMoments
        let frameLimit = max(1, maxFrames ?? 48)
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let useLLMPromptCompiler = overrideUseLLMPromptCompiler ?? shotSettings.useLLMShotPromptCompiler

        guard !isExecute || store.isGeminiAllowed() else {
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: 0,
                maxCostUSD: maxCostUSD,
                records: [],
                blockers: [.init(code: .failedProviderError, message: "Gemini image generation is disabled. Enable it in Inspector > Tools before execute mode.", field: "geminiAllowed")]
            )
        }

        if isExecute, let configurationError = store.geminiImageGenerationAvailabilityError {
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: 0,
                maxCostUSD: maxCostUSD,
                records: [],
                blockers: [.init(code: .failedProviderError, message: configurationError.localizedDescription, field: "geminiConfiguration")]
            )
        }

        guard !isExecute || maxCostUSD != nil else {
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: 0,
                maxCostUSD: nil,
                records: [],
                blockers: [.init(code: .blockedCostCap, message: "execute mode requires maxCostUSD.", field: "maxCostUSD")]
            )
        }

        let specBuilder = EffectiveShotSpecBuilder(store: store)
        let referenceResolver = ReferenceContractResolver(store: store)
        let scenesToRun = store.scenes.filter { scene in sceneFilter?.contains(scene.id) ?? true }
        var frameInputs: [(scene: AnimationScene, shotIndex: Int, spec: EffectiveShotSpec, contract: ReferenceContract, referenceContractPath: String?)] = []
        let momentCount = max(1, moments.count)
        let shotInputLimit = max(1, Int(ceil(Double(frameLimit) / Double(momentCount))))
        var hitFrameLimit = false

        sceneLoop:
        for scene in scenesToRun {
            for index in scene.shots.indices {
                let shot = scene.shots[index]
                if let shotFilter, shot.id != shotFilter { continue }
                guard frameInputs.count < shotInputLimit else {
                    hitFrameLimit = true
                    break sceneLoop
                }
                let spec = specBuilder.build(scene: scene, shotIndex: index, projectRoot: projectRoot)
                do {
                    let resolved = try referenceResolver.resolve(spec: spec, projectRoot: projectRoot, write: true)
                    let blockingReferenceIssues = resolved.contract.blockers.filter { $0.severity != "warning" }
                    if !blockingReferenceIssues.isEmpty {
                        blockers.append(contentsOf: blockingReferenceIssues)
                        continue
                    }
                    frameInputs.append((scene, index, spec, resolved.contract, resolved.url?.path))
                } catch {
                    blockers.append(.init(code: .failedProviderError, message: "Reference resolve failed for shot \(shot.name): \(error.localizedDescription)", field: "references"))
                }
            }
        }

        if hitFrameLimit {
            blockers.append(.init(code: .blockedCostCap, message: "Frame request was capped at maxFrames=\(frameLimit).", field: "maxFrames", severity: "warning"))
        }

        let plannedFrameCount = min(frameInputs.count * momentCount, frameLimit)
        let estimatedCost = Double(plannedFrameCount) * model.estimatedCost(for: imageSize)
        if let maxCostUSD, estimatedCost > maxCostUSD {
            blockers.append(.init(code: .blockedCostCap, message: "Estimated Vertex cost $\(String(format: "%.4f", estimatedCost)) exceeds cap $\(String(format: "%.2f", maxCostUSD)).", field: "maxCostUSD"))
            return .init(
                ok: false,
                mode: mode,
                isDryRun: isDryRun,
                model: model.rawValue,
                imageSize: imageSize,
                estimatedCostUSD: estimatedCost,
                maxCostUSD: maxCostUSD,
                records: records,
                blockers: blockers
            )
        }

        let generator = ImagineGenerationService()
        for input in frameInputs {
            var workingGallery = store.imagineGallery(for: input.scene.id, shotIndex: input.shotIndex)
                ?? ImagineSceneShotGallery(shotID: input.scene.shots[input.shotIndex].id, sceneID: input.scene.id)
            let previousGallery = input.shotIndex > 0 ? store.imagineGallery(for: input.scene.id, shotIndex: input.shotIndex - 1) : nil
            let referencePaths = input.contract.usableReferences
                .filter { $0.role != .style }
                .map(\.path)
            let sceneSlug = sceneSlug(for: input.scene)

            for moment in moments {
                guard records.count < frameLimit else { break }
                var plan = ShotFrameGenerationPlanResolver.resolve(
                    input: .init(
                        projectRoot: projectRoot,
                        sceneID: input.scene.id,
                        shotID: input.scene.shots[input.shotIndex].id,
                        shotIndex: input.shotIndex,
                        moment: moment,
                        prompt: input.spec.prompt,
                        gallery: workingGallery,
                        previousShotGallery: previousGallery,
                        automaticReferenceImagePaths: referencePaths,
                        manualReferenceCount: input.contract.usableReferences.filter { $0.status == .pinned }.count,
                        cameraShot: input.spec.cameraShot.flatMap(CameraShot.init(rawValue:)),
                        cameraMovement: nil,
                        generatedAspectRatio: shotSettings.generatedAspectRatio,
                        generatedImageSize: imageSize,
                        extractionTargetAspectRatio: shotSettings.extractionTargetAspectRatio,
                        finalDeliveryAspectRatio: shotSettings.finalDeliveryAspectRatio,
                        requirePickedReferences: shotSettings.requirePickedReferences,
                        requireRatedReferences: shotSettings.requireRatedReferences,
                        minimumReferenceRating: shotSettings.minimumReferenceRating,
                        includeOpenMatteCropContractText: shotSettings.includeOpenMatteCropContractText,
                        forbidVisibleFrameGuides: shotSettings.forbidVisibleFrameGuides
                    )
                )
                var llmCompilerWarnings: [AutomationBlocker] = []
                if useLLMPromptCompiler {
                    do {
                        let compiled = try await LLMShotPromptCompilerService().compile(
                            .init(
                                spec: input.spec,
                                contract: input.contract,
                                moment: moment,
                                deterministicPrompt: plan.executionPrompt,
                                openMatteInstruction: plan.openMattePlan?.promptInstruction ?? "",
                                generatedAspectRatio: plan.openMattePlan?.generatedAspectRatio ?? shotSettings.generatedAspectRatio,
                                generatedImageSize: plan.openMattePlan?.generatedImageSize ?? imageSize,
                                projectRoot: projectRoot,
                                provider: shotSettings.llmShotPromptProvider,
                                model: shotSettings.llmShotPromptModel,
                                apiKey: shotSettings.llmShotPromptProvider == .vertexGemini ? "" : store.supplementalLLMConfiguration(modelOverride: shotSettings.llmShotPromptModel).apiKey
                            )
                        )
                        if plan.usesEditPrompt {
                            plan.editInstruction = compiled.prompt
                        } else {
                            plan.effectivePrompt = compiled.prompt
                        }
                        let warningText = compiled.warnings
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " | ")
                        if !warningText.isEmpty {
                            llmCompilerWarnings.append(.init(code: .failedProviderError, message: "LLM prompt compiler warning: \(warningText)", field: "llmPromptCompiler", severity: "warning"))
                        }
                    } catch {
                        llmCompilerWarnings.append(.init(code: .failedProviderError, message: "LLM prompt compiler failed; deterministic prompt retained: \(error.localizedDescription)", field: "llmPromptCompiler", severity: "warning"))
                    }
                }
                var record = makeRecord(
                    sceneID: input.scene.id,
                    shotID: input.scene.shots[input.shotIndex].id,
                    shotIndex: input.shotIndex,
                    moment: moment,
                    plan: plan,
                    model: model,
                    imageSize: imageSize,
                    referenceContractPath: input.referenceContractPath,
                    estimatedCostUSD: model.estimatedCost(for: plan.openMattePlan?.generatedImageSize ?? imageSize),
                    status: isDryRun ? "planned" : "running"
                )
                record.blockers.append(contentsOf: llmCompilerWarnings)

                let missingEditSource = moment != .beginning
                    && plan.decision.reasons.contains(.sourceImageMissing)
                    && !plan.decision.reasons.contains(.hardContinuityBreak)
                if missingEditSource || !plan.canExecute {
                    record.status = "blocked"
                    record.blockers.append(.init(code: .blockedMissingEditSource, message: "\(moment.rawValue) needs an approved/readable prior frame for edit continuity before execution.", field: "sourceImage"))
                    records.append(record)
                    if isExecute { try? writeFrameRecord(record, projectRoot: projectRoot) }
                    continue
                }

                if isDryRun {
                    records.append(record)
                    continue
                }

                var activityID: UUID?
                do {
                    try writeFrameRecord(record, projectRoot: projectRoot)
                    activityID = store.registerGeminiActivity(
                        kind: .immediate,
                        title: "\(input.scene.name) • Shot \(input.shotIndex + 1) • \(moment.rawValue)",
                        source: "Automation Frames API"
                    )
                    store.logGeminiAPICall(endpoint: "image-generation", source: "AutomationFrameGenerationService.run()")
                    let savedURL = try await generator.generateWithGemini(
                        plan: plan,
                        manualReferenceImages: [],
                        model: model,
                        apiKey: store.geminiAPIKey,
                        owpURL: projectRoot,
                        sceneSlug: sceneSlug,
                        shotIndex: input.shotIndex,
                        moment: moment
                    )
                    workingGallery.appendPath(savedURL.path, for: moment)
                    record.status = "completed"
                    record.updatedAt = Date()
                    record.outputPath = savedURL.path
                    record.promptPath = savedURL.deletingPathExtension().appendingPathExtension("prompt.txt").path
                    record.responsePath = savedURL.deletingPathExtension().appendingPathExtension("response.txt").path
                    record.planPath = savedURL.deletingPathExtension().appendingPathExtension("plan.json").path
                    try writeFrameRecord(record, projectRoot: projectRoot)
                    registerGeneratedShotImage(savedURL, scene: input.scene, shotIndex: input.shotIndex, moment: moment, mode: plan.mode.rawValue)
                    if let activityID {
                        store.updateGeminiActivity(activityID, status: .completed, outputFilename: savedURL.lastPathComponent)
                    }
                    records.append(record)
                } catch {
                    record.status = "failed_provider_error"
                    record.updatedAt = Date()
                    record.errorMessage = error.localizedDescription
                    record.blockers.append(.init(code: .failedProviderError, message: error.localizedDescription, field: "provider"))
                    try? writeFrameRecord(record, projectRoot: projectRoot)
                    if let activityID {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                    }
                    records.append(record)
                }
                await Task.yield()
            }
            if isExecute {
                store.refreshImagineGalleryFromDisk(sceneID: input.scene.id)
            }
        }

        let hasBlockingRecords = records.contains { record in
            record.status == "blocked" || record.status.hasPrefix("failed")
        }
        return .init(
            ok: blockers.filter { $0.severity == "blocking" }.isEmpty && !hasBlockingRecords,
            mode: mode,
            isDryRun: isDryRun,
            model: model.rawValue,
            imageSize: imageSize,
            estimatedCostUSD: estimatedCost,
            maxCostUSD: maxCostUSD,
            records: records,
            blockers: blockers
        )
    }

    private func makeRecord(
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int,
        moment: ImagineShotMoment,
        plan: ShotFrameGenerationPlan,
        model: GeminiModel,
        imageSize: String,
        referenceContractPath: String?,
        estimatedCostUSD: Double,
        status: String
    ) -> GeneratedFrameRecord {
        .init(
            sceneID: sceneID,
            shotID: shotID,
            shotIndex: shotIndex,
            moment: moment.rawValue,
            provider: currentImageGenerationProviderLabel(),
            model: model.rawValue,
            imageSize: plan.openMattePlan?.generatedImageSize ?? imageSize,
            aspectRatio: plan.openMattePlan?.generatedAspectRatio ?? ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
            generationMode: plan.mode.rawValue,
            status: status,
            estimatedCostUSD: estimatedCostUSD,
            referenceContractPath: referenceContractPath,
            referencePaths: plan.referenceImagePaths,
            blockers: plan.canExecute ? [] : [.init(code: .blockedMissingEditSource, message: "Plan cannot execute without a readable source image.", field: "sourceImage")]
        )
    }

    private func registerGeneratedShotImage(
        _ url: URL,
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment,
        mode: String
    ) {
        guard shotIndex >= 0, shotIndex < scene.shots.count else { return }
        let shot = scene.shots[shotIndex]
        store.registerImageAsset(
            path: url.standardizedFileURL.path,
            linkKind: .sceneShotImage,
            ownerID: shot.id.uuidString,
            ownerParentID: scene.id.uuidString,
            moment: moment.directoryName,
            workflow: "automation_frame_generation",
            context: [
                "sceneID": scene.id.uuidString,
                "sceneName": scene.name,
                "shotID": shot.id.uuidString,
                "shotName": shot.name,
                "shotOrder": "\(shotIndex + 1)",
                "moment": moment.directoryName,
                "generator": currentImageGenerationProviderLabel(),
                "mode": mode
            ],
            analysisMode: .immediate
        )
    }
}

@available(macOS 26.0, *)
func generatedFrameRecordURL(projectRoot: URL, sceneID: UUID, shotID: UUID, moment: ImagineShotMoment) -> URL {
    AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "generated-frames")
        .appendingPathComponent(sceneID.uuidString, isDirectory: true)
        .appendingPathComponent(shotID.uuidString, isDirectory: true)
        .appendingPathComponent("\(moment.directoryName)-latest.json")
}

@available(macOS 26.0, *)
func writeFrameRecord(_ record: GeneratedFrameRecord, projectRoot: URL) throws {
    guard let moment = ImagineShotMoment(rawValue: record.moment) else { return }
    let url = generatedFrameRecordURL(projectRoot: projectRoot, sceneID: record.sceneID, shotID: record.shotID, moment: moment)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeCodable(record, to: url)
}

@available(macOS 26.0, *)
func readFrameRecord(projectRoot: URL, sceneID: UUID, shotID: UUID, moment: ImagineShotMoment) -> GeneratedFrameRecord? {
    let url = generatedFrameRecordURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, moment: moment)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(GeneratedFrameRecord.self, from: data)
}

@available(macOS 26.0, *)
func sceneSlug(for scene: AnimationScene) -> String {
    scene.name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
}
