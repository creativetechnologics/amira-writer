import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum ShotFrameGenerationPlanResolver {

    struct Input {
        var projectRoot: URL
        var sceneID: UUID
        var shotID: UUID
        var shotIndex: Int
        var moment: ImagineShotMoment
        var prompt: String
        var gallery: ImagineSceneShotGallery?
        var previousShotGallery: ImagineSceneShotGallery?
        var automaticReferenceImagePaths: [String]
        var manualReferenceCount: Int
        var cameraShot: CameraShot?
        var cameraMovement: CameraMovement?
        var generatedAspectRatio: String
        var generatedImageSize: String
        var extractionTargetAspectRatio: String
        var finalDeliveryAspectRatio: String
        var requirePickedReferences: Bool
        var requireRatedReferences: Bool
        var minimumReferenceRating: Int
        var includeOpenMatteCropContractText: Bool
        var forbidVisibleFrameGuides: Bool

        init(
            projectRoot: URL,
            sceneID: UUID,
            shotID: UUID,
            shotIndex: Int,
            moment: ImagineShotMoment,
            prompt: String,
            gallery: ImagineSceneShotGallery?,
            previousShotGallery: ImagineSceneShotGallery? = nil,
            automaticReferenceImagePaths: [String] = [],
            manualReferenceCount: Int = 0,
            cameraShot: CameraShot? = nil,
            cameraMovement: CameraMovement? = nil,
            generatedAspectRatio: String = ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
            generatedImageSize: String = ShotFrameOpenMattePlan.defaultGeneratedImageSize,
            extractionTargetAspectRatio: String = ShotFrameOpenMattePlan.defaultExtractionTargetAspectRatio,
            finalDeliveryAspectRatio: String = ShotFrameOpenMattePlan.defaultFinalDeliveryAspectRatio,
            requirePickedReferences: Bool = true,
            requireRatedReferences: Bool = true,
            minimumReferenceRating: Int = 1,
            includeOpenMatteCropContractText: Bool = false,
            forbidVisibleFrameGuides: Bool = true
        ) {
            self.projectRoot = projectRoot
            self.sceneID = sceneID
            self.shotID = shotID
            self.shotIndex = shotIndex
            self.moment = moment
            self.prompt = prompt
            self.gallery = gallery
            self.previousShotGallery = previousShotGallery
            self.automaticReferenceImagePaths = automaticReferenceImagePaths
            self.manualReferenceCount = manualReferenceCount
            self.cameraShot = cameraShot
            self.cameraMovement = cameraMovement
            self.generatedAspectRatio = generatedAspectRatio
            self.generatedImageSize = generatedImageSize
            self.extractionTargetAspectRatio = extractionTargetAspectRatio
            self.finalDeliveryAspectRatio = finalDeliveryAspectRatio
            self.requirePickedReferences = requirePickedReferences
            self.requireRatedReferences = requireRatedReferences
            self.minimumReferenceRating = minimumReferenceRating
            self.includeOpenMatteCropContractText = includeOpenMatteCropContractText
            self.forbidVisibleFrameGuides = forbidVisibleFrameGuides
        }
    }

    static func resolve(input: Input) -> ShotFrameGenerationPlan {
        let promptProtocol = ShotPromptProtocolStore.load(projectRoot: input.projectRoot)
        let storyboard = storyboardAttachment(
            projectRoot: input.projectRoot,
            sceneID: input.sceneID,
            shotID: input.shotID,
            moment: input.moment
        )
        let hasManualReferences = input.manualReferenceCount > 0
        let hasAutomaticReferences = !input.automaticReferenceImagePaths.isEmpty
        var referenceImagePaths: [String] = []

        if let storyboardImagePath = storyboard.imagePath {
            referenceImagePaths.append(storyboardImagePath)
        }

        let hardBreak = containsHardContinuityBreak(in: input.prompt, promptProtocol: promptProtocol)
        let openMattePlan = makeOpenMattePlan(input: input, promptProtocol: promptProtocol)

        switch input.moment {
        case .beginning:
            if let previousEnd = selectedOrNewestPath(
                in: input.previousShotGallery,
                moment: .end,
                requirePickedReferences: input.requirePickedReferences
            ) {
                referenceImagePaths.append(previousEnd)
            }
            referenceImagePaths.append(contentsOf: input.automaticReferenceImagePaths)
            return generatePlan(
                input: input,
                storyboard: storyboard,
                openMattePlan: openMattePlan,
                referenceImagePaths: referenceImagePaths,
                extraReasons: contextualReferenceReasons(
                    hasManualReferences: hasManualReferences,
                    hasAutomaticReferences: hasAutomaticReferences
                ),
                promptProtocol: promptProtocol
            )

        case .middle:
            referenceImagePaths.append(contentsOf: input.automaticReferenceImagePaths)
            guard !hardBreak,
                  let sourcePath = approvedSourcePath(
                    in: input.gallery,
                    moment: .beginning,
                    requirePickedReferences: input.requirePickedReferences,
                    requireRatedReferences: input.requireRatedReferences,
                    minimumReferenceRating: input.minimumReferenceRating
                  ) else {
                return generatePlan(
                    input: input,
                    storyboard: storyboard,
                    openMattePlan: openMattePlan,
                    referenceImagePaths: referenceImagePaths,
                    extraReasons: fallbackReasons(
                        hardBreak: hardBreak,
                        hasManualReferences: hasManualReferences,
                        hasAutomaticReferences: hasAutomaticReferences
                    ),
                    promptProtocol: promptProtocol
                )
            }
            let source = ShotFrameSourceImage(
                path: sourcePath,
                source: .beginningFrame,
                moment: .beginning,
                confidence: 0.95,
                note: "Use the generated beginning frame as the continuity source for the middle frame."
            )
            return editPlan(
                input: input,
                source: source,
                storyboard: storyboard,
                openMattePlan: openMattePlan,
                referenceImagePaths: referenceImagePaths,
                hasManualReferences: hasManualReferences,
                hasAutomaticReferences: hasAutomaticReferences,
                promptProtocol: promptProtocol
            )

        case .end:
            referenceImagePaths.append(contentsOf: input.automaticReferenceImagePaths)
            if !hardBreak,
               let middlePath = approvedSourcePath(
                in: input.gallery,
                moment: .middle,
                requirePickedReferences: input.requirePickedReferences,
                requireRatedReferences: input.requireRatedReferences,
                minimumReferenceRating: input.minimumReferenceRating
               ) {
                let source = ShotFrameSourceImage(
                    path: middlePath,
                    source: .middleFrame,
                    moment: .middle,
                    confidence: 0.97,
                    note: "Use the generated middle frame as the closest continuity source for the end frame."
                )
                return editPlan(
                    input: input,
                    source: source,
                    storyboard: storyboard,
                    openMattePlan: openMattePlan,
                    referenceImagePaths: referenceImagePaths,
                    hasManualReferences: hasManualReferences,
                    hasAutomaticReferences: hasAutomaticReferences,
                    promptProtocol: promptProtocol
                )
            }
            if !hardBreak,
               let beginningPath = approvedSourcePath(
                in: input.gallery,
                moment: .beginning,
                requirePickedReferences: input.requirePickedReferences,
                requireRatedReferences: input.requireRatedReferences,
                minimumReferenceRating: input.minimumReferenceRating
               ) {
                let source = ShotFrameSourceImage(
                    path: beginningPath,
                    source: .beginningFrame,
                    moment: .beginning,
                    confidence: 0.86,
                    note: "No middle frame exists yet, so use the beginning frame as the continuity source for the end frame."
                )
                return editPlan(
                    input: input,
                    source: source,
                    storyboard: storyboard,
                    openMattePlan: openMattePlan,
                    referenceImagePaths: referenceImagePaths,
                    hasManualReferences: hasManualReferences,
                    hasAutomaticReferences: hasAutomaticReferences,
                    promptProtocol: promptProtocol
                )
            }
            return generatePlan(
                input: input,
                storyboard: storyboard,
                openMattePlan: openMattePlan,
                referenceImagePaths: referenceImagePaths,
                extraReasons: fallbackReasons(
                    hardBreak: hardBreak,
                    hasManualReferences: hasManualReferences,
                    hasAutomaticReferences: hasAutomaticReferences
                ),
                promptProtocol: promptProtocol
            )
        }
    }

    private static func generatePlan(
        input: Input,
        storyboard: StoryboardAttachment,
        openMattePlan: ShotFrameOpenMattePlan,
        referenceImagePaths: [String],
        extraReasons: [ShotFrameStrategyReason] = [],
        promptProtocol: ShotPromptProtocolSettings
    ) -> ShotFrameGenerationPlan {
        var plan = ShotFrameGenerationPlan.defaultGenerate(
            sceneID: input.sceneID,
            shotID: input.shotID,
            shotIndex: input.shotIndex,
            moment: input.moment,
            prompt: generationPrompt(
                basePrompt: input.prompt,
                moment: input.moment,
                storyboardImagePath: storyboard.imagePath,
                openMattePlan: openMattePlan,
                promptProtocol: promptProtocol
            ),
            storyboardImagePath: storyboard.imagePath,
            storyboardAnalysisPath: storyboard.analysisPath,
            referenceImagePaths: deduplicated(referenceImagePaths),
            openMattePlan: openMattePlan
        )
        if !extraReasons.isEmpty {
            plan.decision.reasons = deduplicated(plan.decision.reasons + extraReasons)
        }
        return plan
    }

    private static func editPlan(
        input: Input,
        source: ShotFrameSourceImage,
        storyboard: StoryboardAttachment,
        openMattePlan: ShotFrameOpenMattePlan,
        referenceImagePaths: [String],
        hasManualReferences: Bool,
        hasAutomaticReferences: Bool,
        promptProtocol: ShotPromptProtocolSettings
    ) -> ShotFrameGenerationPlan {
        var plan = ShotFrameGenerationPlan.defaultEdit(
            sceneID: input.sceneID,
            shotID: input.shotID,
            shotIndex: input.shotIndex,
            moment: input.moment,
            prompt: input.prompt,
            sourceImage: source,
            editInstruction: editInstruction(
                basePrompt: input.prompt,
                moment: input.moment,
                source: source,
                storyboardImagePath: storyboard.imagePath,
                openMattePlan: openMattePlan,
                promptProtocol: promptProtocol
            ),
            storyboardImagePath: storyboard.imagePath,
            storyboardAnalysisPath: storyboard.analysisPath,
            referenceImagePaths: deduplicated(referenceImagePaths),
            openMattePlan: openMattePlan
        )
        plan.decision.reasons = deduplicated(
            plan.decision.reasons + contextualReferenceReasons(
                hasManualReferences: hasManualReferences,
                hasAutomaticReferences: hasAutomaticReferences
            )
        )
        return plan
    }

    private static func fallbackReasons(
        hardBreak: Bool,
        hasManualReferences: Bool,
        hasAutomaticReferences: Bool
    ) -> [ShotFrameStrategyReason] {
        var reasons: [ShotFrameStrategyReason] = []
        if hardBreak {
            reasons.append(.hardContinuityBreak)
        } else {
            reasons.append(.sourceImageMissing)
        }
        reasons.append(.safetyFallbackGenerate)
        if hasManualReferences {
            reasons.append(.manualReferenceImagesAvailable)
        }
        if hasAutomaticReferences {
            reasons.append(.imageIntelligenceReferencesAvailable)
        }
        return reasons
    }

    private static func contextualReferenceReasons(
        hasManualReferences: Bool,
        hasAutomaticReferences: Bool
    ) -> [ShotFrameStrategyReason] {
        var reasons: [ShotFrameStrategyReason] = []
        if hasManualReferences {
            reasons.append(.manualReferenceImagesAvailable)
        }
        if hasAutomaticReferences {
            reasons.append(.imageIntelligenceReferencesAvailable)
        }
        return reasons
    }

    private static func generationPrompt(
        basePrompt: String,
        moment: ImagineShotMoment,
        storyboardImagePath: String?,
        openMattePlan: ShotFrameOpenMattePlan,
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        var lines: [String] = []
        for section in promptProtocol.framePlan.generationOrder {
            switch section {
            case .basePrompt:
                lines.append(basePrompt)
            case .openMatteInstruction:
                lines.append(openMattePlan.promptInstruction)
            case .momentProgression:
                lines.append(
                    momentProgressionInstruction(
                        moment,
                        basePrompt: basePrompt,
                        openMattePlan: openMattePlan,
                        promptProtocol: promptProtocol
                    )
                )
            case .storyboardGuidance:
                if storyboardImagePath != nil {
                    lines.append(promptProtocol.framePlan.templates.storyboardGuidanceLine)
                }
            case .continuitySource, .noRedesign, .returnOneImage:
                continue
            }
        }
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func editInstruction(
        basePrompt: String,
        moment: ImagineShotMoment,
        source: ShotFrameSourceImage,
        storyboardImagePath: String?,
        openMattePlan: ShotFrameOpenMattePlan,
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        let continuitySource = ShotPromptProtocolStore.applyTemplate(
            promptProtocol.framePlan.templates.continuitySourceLineTemplate,
            values: ["source": source.source.displayName]
        )

        var lines: [String] = []
        for section in promptProtocol.framePlan.editOrder {
            switch section {
            case .basePrompt:
                lines.append(basePrompt)
            case .openMatteInstruction:
                lines.append(openMattePlan.promptInstruction)
            case .continuitySource:
                lines.append(continuitySource)
            case .noRedesign:
                lines.append(promptProtocol.framePlan.templates.noRedesignLine)
            case .momentProgression:
                lines.append(
                    momentProgressionInstruction(
                        moment,
                        basePrompt: basePrompt,
                        openMattePlan: openMattePlan,
                        promptProtocol: promptProtocol
                    )
                )
            case .storyboardGuidance:
                if storyboardImagePath != nil {
                    lines.append(promptProtocol.framePlan.templates.storyboardGuidanceLine)
                }
            case .returnOneImage:
                lines.append(promptProtocol.framePlan.templates.returnOneImageLine)
            }
        }
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private struct StoryboardAttachment {
        var imagePath: String?
        var analysisPath: String?
    }

    private static func storyboardAttachment(
        projectRoot: URL,
        sceneID: UUID,
        shotID: UUID,
        moment: ImagineShotMoment
    ) -> StoryboardAttachment {
        let paths = ProjectPaths(root: projectRoot)
        let frame = storyboardFrame(for: moment)
        let imageURL = paths.shotStoryboardImage(sceneID: sceneID, shotID: shotID, frame: frame)
        let analysisURL = paths.shotStoryboardAnalysisJSON(sceneID: sceneID, shotID: shotID, frame: frame)
        return StoryboardAttachment(
            imagePath: FileManager.default.fileExists(atPath: imageURL.path) ? imageURL.path : nil,
            analysisPath: FileManager.default.fileExists(atPath: analysisURL.path) ? analysisURL.path : nil
        )
    }

    private static func storyboardFrame(for moment: ImagineShotMoment) -> StoryboardFrame {
        switch moment {
        case .beginning: .begin
        case .middle: .middle
        case .end: .end
        }
    }

    private static func selectedOrNewestPath(
        in gallery: ImagineSceneShotGallery?,
        moment: ImagineShotMoment,
        requirePickedReferences: Bool
    ) -> String? {
        guard let gallery else { return nil }
        if let selected = gallery.selectedPath(for: moment),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: selected),
           isApprovedImageReference(selected, requirePickedReferences: requirePickedReferences, requireRatedReferences: false, minimumReferenceRating: 0) {
            return selected
        }
        return gallery.paths(for: moment).last { path in
            FileManager.default.fileExists(atPath: path)
                && isApprovedImageReference(path, requirePickedReferences: requirePickedReferences, requireRatedReferences: false, minimumReferenceRating: 0)
        }
    }

    private static func approvedSourcePath(
        in gallery: ImagineSceneShotGallery?,
        moment: ImagineShotMoment,
        requirePickedReferences: Bool,
        requireRatedReferences: Bool,
        minimumReferenceRating: Int
    ) -> String? {
        guard let gallery else { return nil }
        let candidates: [String] = {
            var values: [String] = []
            if let selected = gallery.selectedPath(for: moment),
               !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(selected)
            }
            values.append(contentsOf: gallery.paths(for: moment).reversed())
            return deduplicated(values)
        }()

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if isApprovedImageReference(
                path,
                requirePickedReferences: requirePickedReferences,
                requireRatedReferences: requireRatedReferences,
                minimumReferenceRating: minimumReferenceRating
            ) {
                return path
            }
        }
        return nil
    }

    private static func isApprovedImageReference(
        _ path: String,
        requirePickedReferences: Bool,
        requireRatedReferences: Bool,
        minimumReferenceRating: Int
    ) -> Bool {
        let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)
        if metadata?.isRejected == true { return false }
        if requirePickedReferences {
            return metadata?.isLiked == true
        }
        if !requireRatedReferences { return true }
        let minRating = min(max(minimumReferenceRating, 1), 5)
        guard let rating = metadata?.rating else { return false }
        return rating >= minRating
    }

    private static func containsHardContinuityBreak(
        in prompt: String,
        promptProtocol: ShotPromptProtocolSettings
    ) -> Bool {
        let lower = prompt.lowercased()
        let hardBreakMarkers = promptProtocol.framePlan.hardContinuityBreakMarkers
        return hardBreakMarkers.contains { lower.contains($0) }
    }

    private static func makeOpenMattePlan(
        input: Input,
        promptProtocol: ShotPromptProtocolSettings
    ) -> ShotFrameOpenMattePlan {
        let intendedShot = input.cameraShot ?? .medium
        let generatedShot = widerShot(for: intendedShot)
        let motion = cropMotion(
            cameraMovement: input.cameraMovement,
            prompt: input.prompt,
            promptProtocol: promptProtocol
        )
        let sourceAspect = aspectRatioValue(input.generatedAspectRatio) ?? (16.0 / 9.0)
        let targetAspect = aspectRatioValue(input.extractionTargetAspectRatio) ?? (16.0 / 9.0)
        let keyframes = cropKeyframes(
            intendedShot: intendedShot,
            motion: motion,
            sourceAspect: sourceAspect,
            targetAspect: targetAspect,
            promptProtocol: promptProtocol
        )
        let currentCrop = keyframes.first { $0.moment == input.moment }?.cropRect
            ?? keyframes.first?.cropRect
            ?? CropRect(x: 0.08, y: 0.18, width: 0.84, height: 0.63)

        let generatedShotText = generatedShot?.displayName ?? "wider than the intended crop"
        let intendedShotText = intendedShot.displayName
        let cropSummary = cropSummaryText(currentCrop)
        let openMatteTemplates = promptProtocol.framePlan.templates.openMatte
        let promptInstruction: String
        if input.includeOpenMatteCropContractText {
            promptInstruction = [
                ShotPromptProtocolStore.applyTemplate(
                    openMatteTemplates.detailedLine1Template,
                    values: [
                        "generatedAspectRatio": input.generatedAspectRatio,
                        "generatedImageSize": input.generatedImageSize
                    ]
                ),
                ShotPromptProtocolStore.applyTemplate(
                    openMatteTemplates.detailedLine2Template,
                    values: [
                        "generatedShot": generatedShotText,
                        "intendedShot": intendedShotText
                    ]
                ),
                openMatteTemplates.detailedLine3Template,
                ShotPromptProtocolStore.applyTemplate(
                    openMatteTemplates.detailedLine4Template,
                    values: ["cropSummary": cropSummary]
                )
            ].joined(separator: " ")
        } else {
            var compact = [
                ShotPromptProtocolStore.applyTemplate(
                    openMatteTemplates.compactLine1Template,
                    values: [
                        "generatedAspectRatio": input.generatedAspectRatio,
                        "generatedImageSize": input.generatedImageSize
                    ]
                ),
                openMatteTemplates.compactLine2Template
            ]
            if input.forbidVisibleFrameGuides {
                compact.append(openMatteTemplates.compactGuidesForbiddenLine)
            }
            promptInstruction = compact.joined(separator: " ")
        }

        return ShotFrameOpenMattePlan(
            generatedAspectRatio: input.generatedAspectRatio,
            generatedImageSize: input.generatedImageSize,
            extractionTargetAspectRatio: input.extractionTargetAspectRatio,
            finalDeliveryAspectRatio: input.finalDeliveryAspectRatio,
            intendedCameraShot: intendedShot,
            generatedCameraShot: generatedShot,
            cropMotion: motion,
            cropRect: currentCrop,
            cropKeyframes: keyframes,
            promptInstruction: promptInstruction
        )
    }

    private static func cropMotion(
        cameraMovement: CameraMovement?,
        prompt: String,
        promptProtocol: ShotPromptProtocolSettings
    ) -> ShotFrameCropMotion {
        let lower = prompt.lowercased()
        let keywordTemplates = promptProtocol.framePlan.motionKeywords
        if keywordTemplates.keywords(for: .tiltUp).contains(where: { lower.contains($0) }) { return .tiltUp }
        if keywordTemplates.keywords(for: .tiltDown).contains(where: { lower.contains($0) }) { return .tiltDown }
        if keywordTemplates.keywords(for: .panLeft).contains(where: { lower.contains($0) }) { return .panLeft }
        if keywordTemplates.keywords(for: .panRight).contains(where: { lower.contains($0) }) { return .panRight }
        if keywordTemplates.keywords(for: .zoomIn).contains(where: { lower.contains($0) }) { return .zoomIn }
        if keywordTemplates.keywords(for: .zoomOut).contains(where: { lower.contains($0) }) { return .zoomOut }
        if keywordTemplates.keywords(for: .track).contains(where: { lower.contains($0) }) { return .track }

        switch cameraMovement {
        case .panLeft: return .panLeft
        case .panRight: return .panRight
        case .panUp: return .tiltUp
        case .panDown: return .tiltDown
        case .zoomIn: return .zoomIn
        case .zoomOut: return .zoomOut
        case .track: return .track
        case .shake: return .shake
        case .hold, .none: return .hold
        }
    }

    private static func cropKeyframes(
        intendedShot: CameraShot,
        motion: ShotFrameCropMotion,
        sourceAspect: Double,
        targetAspect: Double,
        promptProtocol: ShotPromptProtocolSettings
    ) -> [ShotFrameCropKeyframe] {
        ImagineShotMoment.allCases.map { moment in
            let progress = progressValue(for: moment)
            let baseWidth = cropWidth(for: intendedShot, promptProtocol: promptProtocol)
            let sizeMultiplier: Double
            switch motion {
            case .zoomIn:
                sizeMultiplier = interpolated(start: 1.12, end: 0.84, progress: progress)
            case .zoomOut:
                sizeMultiplier = interpolated(start: 0.84, end: 1.12, progress: progress)
            default:
                sizeMultiplier = 1.0
            }

            let width = min(0.94, max(0.28, baseWidth * sizeMultiplier))
            let height = normalizedCropHeight(
                width: width,
                sourceAspect: sourceAspect,
                targetAspect: targetAspect
            )
            let shiftX = min(0.16, max(0.03, (1.0 - width) * 0.42))
            let shiftY = min(0.14, max(0.025, (1.0 - height) * 0.32))
            var centerX = 0.5
            var centerY = 0.5

            switch motion {
            case .panLeft:
                centerX = interpolated(start: 0.5 + shiftX, end: 0.5 - shiftX, progress: progress)
            case .panRight, .track:
                centerX = interpolated(start: 0.5 - shiftX, end: 0.5 + shiftX, progress: progress)
            case .tiltUp:
                centerY = interpolated(start: 0.5 + shiftY, end: 0.5 - shiftY, progress: progress)
            case .tiltDown:
                centerY = interpolated(start: 0.5 - shiftY, end: 0.5 + shiftY, progress: progress)
            case .shake:
                centerX += moment == .middle ? min(0.04, shiftX) : 0
                centerY += moment == .middle ? -min(0.035, shiftY) : 0
            case .hold, .zoomIn, .zoomOut:
                break
            }

            return ShotFrameCropKeyframe(
                moment: moment,
                cropRect: cropRect(centerX: centerX, centerY: centerY, width: width, height: height),
                note: "\(motion.displayName) crop keyframe for \(intendedShot.displayName)."
            )
        }
    }

    private static func cropWidth(
        for shot: CameraShot,
        promptProtocol: ShotPromptProtocolSettings
    ) -> Double {
        let value = promptProtocol.framePlan.cropWidthByIntendedShot[shot.rawValue]
            ?? ShotFramePromptProtocol.default.cropWidthByIntendedShot[shot.rawValue]
            ?? 0.72
        return min(max(value, 0.20), 0.98)
    }

    private static func widerShot(for shot: CameraShot) -> CameraShot? {
        switch shot {
        case .extremeWide: .extremeWide
        case .wide: .extremeWide
        case .medium: .wide
        case .mediumClose: .medium
        case .close: .mediumClose
        case .extremeClose: .close
        }
    }

    private static func progressValue(for moment: ImagineShotMoment) -> Double {
        switch moment {
        case .beginning: 0
        case .middle: 0.5
        case .end: 1
        }
    }

    private static func normalizedCropHeight(
        width: Double,
        sourceAspect: Double,
        targetAspect: Double
    ) -> Double {
        let rawHeight = width * sourceAspect / targetAspect
        if rawHeight <= 0.94 {
            return max(0.20, rawHeight)
        }
        return 0.94
    }

    private static func cropRect(
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double
    ) -> CropRect {
        let safeWidth = min(0.98, max(0.05, width))
        let safeHeight = min(0.98, max(0.05, height))
        let x = min(max(centerX - safeWidth / 2, 0), 1 - safeWidth)
        let y = min(max(centerY - safeHeight / 2, 0), 1 - safeHeight)
        return CropRect(x: x, y: y, width: safeWidth, height: safeHeight)
    }

    private static func aspectRatioValue(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              height > 0 else { return nil }
        return width / height
    }

    private static func interpolated(start: Double, end: Double, progress: Double) -> Double {
        start + ((end - start) * progress)
    }

    private static func cropSummaryText(_ rect: CropRect) -> String {
        "x \(String(format: "%.3f", rect.x)), y \(String(format: "%.3f", rect.y)), w \(String(format: "%.3f", rect.width)), h \(String(format: "%.3f", rect.height))"
    }

    private enum MotionProgressionProfile {
        case leftToRight
        case rightToLeft
        case bottomToTop
        case topToBottom
        case zoomIn
        case zoomOut
    }

    private static func momentProgressionInstruction(
        _ moment: ImagineShotMoment,
        basePrompt: String,
        openMattePlan: ShotFrameOpenMattePlan,
        promptProtocol: ShotPromptProtocolSettings
    ) -> String {
        let genericLine: String = switch moment {
        case .beginning:
            promptProtocol.framePlan.templates.momentProgressionBeginning
        case .middle:
            promptProtocol.framePlan.templates.momentProgressionMiddle
        case .end:
            promptProtocol.framePlan.templates.momentProgressionEnd
        }

        guard let profile = inferredMotionProgressionProfile(
            from: basePrompt,
            cropMotion: openMattePlan.cropMotion
        ) else {
            return genericLine
        }

        guard let spatialLine = spatialMomentInstruction(for: profile, moment: moment) else {
            return genericLine
        }

        return [genericLine, spatialLine]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func inferredMotionProgressionProfile(
        from basePrompt: String,
        cropMotion: ShotFrameCropMotion
    ) -> MotionProgressionProfile? {
        let text = basePrompt.lowercased()

        if containsAny(in: text, patterns: [
            #"left\s*[-]?\s*to\s*[-]?\s*right"#,
            #"from\s+left\s+to\s+right"#,
            #"screen[-\s]?left\s+to\s+screen[-\s]?right"#,
            #"toward[s]?\s+the\s+right"#,
            #"toward[s]?\s+screen[-\s]?right"#,
            #"moves?\s+right"#
        ]) {
            return .leftToRight
        }

        if containsAny(in: text, patterns: [
            #"right\s*[-]?\s*to\s*[-]?\s*left"#,
            #"from\s+right\s+to\s+left"#,
            #"screen[-\s]?right\s+to\s+screen[-\s]?left"#,
            #"toward[s]?\s+the\s+left"#,
            #"toward[s]?\s+screen[-\s]?left"#,
            #"moves?\s+left"#
        ]) {
            return .rightToLeft
        }

        if containsAny(in: text, patterns: [
            #"bottom\s*[-]?\s*to\s*[-]?\s*top"#,
            #"from\s+bottom\s+to\s+top"#,
            #"rises?\s+up"#,
            #"moves?\s+up"#
        ]) {
            return .bottomToTop
        }

        if containsAny(in: text, patterns: [
            #"top\s*[-]?\s*to\s*[-]?\s*bottom"#,
            #"from\s+top\s+to\s+bottom"#,
            #"drops?\s+down"#,
            #"moves?\s+down"#
        ]) {
            return .topToBottom
        }

        if containsAny(in: text, patterns: [
            #"approach(es|ing)?"#,
            #"comes?\s+closer"#,
            #"closing\s+distance"#,
            #"moves?\s+toward\s+camera"#
        ]) {
            return .zoomIn
        }

        if containsAny(in: text, patterns: [
            #"recede(s|ing)?"#,
            #"moves?\s+away"#,
            #"pulls?\s+away"#,
            #"fades?\s+into\s+distance"#
        ]) {
            return .zoomOut
        }

        switch cropMotion {
        case .panRight, .track:
            return .leftToRight
        case .panLeft:
            return .rightToLeft
        case .tiltUp:
            return .bottomToTop
        case .tiltDown:
            return .topToBottom
        case .zoomIn:
            return .zoomIn
        case .zoomOut:
            return .zoomOut
        case .hold, .shake:
            break
        }

        if containsAny(in: text, patterns: [
            #"\bmoves?\b"#,
            #"\bmoved\b"#,
            #"\bmoving\b"#,
            #"\btravels?\b"#,
            #"\btraveled\b"#,
            #"\btraveling\b"#,
            #"\bcrosses\b"#,
            #"\bcrossed\b"#,
            #"\bcrossing\b"#,
            #"\bclimbs\b"#,
            #"\bclimbed\b"#,
            #"\bclimbing\b"#,
            #"\bdrives\b"#,
            #"\bdrove\b"#,
            #"\bdriving\b"#,
            #"\bwalks\b"#,
            #"\bwalked\b"#,
            #"\bwalking\b"#,
            #"\bruns\b"#,
            #"\bran\b"#,
            #"\brunning\b"#,
            #"\bmarches\b"#,
            #"\bmarched\b"#,
            #"\bmarching\b"#,
            #"\badvances\b"#,
            #"\badvanced\b"#,
            #"\badvancing\b"#
        ]) {
            return .leftToRight
        }

        return nil
    }

    private static func spatialMomentInstruction(
        for profile: MotionProgressionProfile,
        moment: ImagineShotMoment
    ) -> String? {
        switch profile {
        case .leftToRight:
            switch moment {
            case .beginning:
                return "Frame-state for this image: place moving subjects on the left third of frame, oriented toward the right."
            case .middle:
                return "Frame-state for this image: place moving subjects in the center of frame, oriented toward the right."
            case .end:
                return "Frame-state for this image: place moving subjects on the right third of frame, oriented toward the right."
            }
        case .rightToLeft:
            switch moment {
            case .beginning:
                return "Frame-state for this image: place moving subjects on the right third of frame, oriented toward the left."
            case .middle:
                return "Frame-state for this image: place moving subjects in the center of frame, oriented toward the left."
            case .end:
                return "Frame-state for this image: place moving subjects on the left third of frame, oriented toward the left."
            }
        case .bottomToTop:
            switch moment {
            case .beginning:
                return "Frame-state for this image: place moving subjects in the lower third of frame, oriented upward."
            case .middle:
                return "Frame-state for this image: place moving subjects in the middle vertical band of frame, oriented upward."
            case .end:
                return "Frame-state for this image: place moving subjects in the upper third of frame, oriented upward."
            }
        case .topToBottom:
            switch moment {
            case .beginning:
                return "Frame-state for this image: place moving subjects in the upper third of frame, oriented downward."
            case .middle:
                return "Frame-state for this image: place moving subjects in the middle vertical band of frame, oriented downward."
            case .end:
                return "Frame-state for this image: place moving subjects in the lower third of frame, oriented downward."
            }
        case .zoomIn:
            switch moment {
            case .beginning:
                return "Frame-state for this image: subjects appear slightly smaller with more surrounding environment visible."
            case .middle:
                return "Frame-state for this image: subjects fill a medium portion of the frame."
            case .end:
                return "Frame-state for this image: subjects appear larger and closer in frame."
            }
        case .zoomOut:
            switch moment {
            case .beginning:
                return "Frame-state for this image: subjects appear larger and closer in frame."
            case .middle:
                return "Frame-state for this image: subjects fill a medium portion of the frame."
            case .end:
                return "Frame-state for this image: subjects appear smaller with more surrounding environment visible."
            }
        }
    }

    private static func containsAny(in text: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
