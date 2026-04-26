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
            finalDeliveryAspectRatio: String = ShotFrameOpenMattePlan.defaultFinalDeliveryAspectRatio
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
        }
    }

    static func resolve(input: Input) -> ShotFrameGenerationPlan {
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

        let hardBreak = containsHardContinuityBreak(in: input.prompt)
        let openMattePlan = makeOpenMattePlan(input: input)

        switch input.moment {
        case .beginning:
            if let previousEnd = selectedOrNewestPath(
                in: input.previousShotGallery,
                moment: .end
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
                )
            )

        case .middle:
            referenceImagePaths.append(contentsOf: input.automaticReferenceImagePaths)
            guard !hardBreak,
                  let sourcePath = selectedOrNewestPath(in: input.gallery, moment: .beginning) else {
                return generatePlan(
                    input: input,
                    storyboard: storyboard,
                    openMattePlan: openMattePlan,
                    referenceImagePaths: referenceImagePaths,
                    extraReasons: fallbackReasons(
                        hardBreak: hardBreak,
                        hasManualReferences: hasManualReferences,
                        hasAutomaticReferences: hasAutomaticReferences
                    )
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
                hasAutomaticReferences: hasAutomaticReferences
            )

        case .end:
            referenceImagePaths.append(contentsOf: input.automaticReferenceImagePaths)
            if !hardBreak,
               let middlePath = selectedOrNewestPath(in: input.gallery, moment: .middle) {
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
                    hasAutomaticReferences: hasAutomaticReferences
                )
            }
            if !hardBreak,
               let beginningPath = selectedOrNewestPath(in: input.gallery, moment: .beginning) {
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
                    hasAutomaticReferences: hasAutomaticReferences
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
                )
            )
        }
    }

    private static func generatePlan(
        input: Input,
        storyboard: StoryboardAttachment,
        openMattePlan: ShotFrameOpenMattePlan,
        referenceImagePaths: [String],
        extraReasons: [ShotFrameStrategyReason] = []
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
                openMattePlan: openMattePlan
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
        hasAutomaticReferences: Bool
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
                openMattePlan: openMattePlan
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
        openMattePlan: ShotFrameOpenMattePlan
    ) -> String {
        var lines = [
            "Generate a \(moment.rawValue.lowercased()) frame for this shot as a full image generation.",
            openMattePlan.promptInstruction,
            "Use the script-derived prompt as the semantic source of truth:",
            basePrompt
        ]
        if storyboardImagePath != nil {
            lines.append("A storyboard reference image is attached. Treat that storyboard as composition/blocking authority where it is clear, while using the text for identity, setting, time of day, and visible detail.")
        }
        lines.append("Keep this frame compatible with the beginning/middle/end triplet for the same shot.")
        return lines.joined(separator: "\n")
    }

    private static func editInstruction(
        basePrompt: String,
        moment: ImagineShotMoment,
        source: ShotFrameSourceImage,
        storyboardImagePath: String?,
        openMattePlan: ShotFrameOpenMattePlan
    ) -> String {
        var lines = [
            "Edit the provided source image to create the \(moment.rawValue.uppercased()) frame of the SAME shot.",
            "The first attached image is the continuity source: \(source.source.displayName). Preserve character identity, wardrobe, place, lighting continuity, camera/lens feel, aspect ratio, screen direction, and geography unless the target beat explicitly requires a small change.",
            openMattePlan.promptInstruction,
            "Do not redesign the scene, replace the cast, change the location, change time of day, or invent a reverse angle.",
            "Only advance the visible action beat to this target prompt:",
            basePrompt
        ]
        if storyboardImagePath != nil {
            lines.append("A storyboard reference image is also attached for the target \(moment.rawValue.lowercased()) frame. Use that drawing as composition/blocking authority where clear, but keep the source image's continuity and production design.")
        }
        lines.append("Return one edited image; no captions, no text overlays, no extra panels.")
        return lines.joined(separator: "\n")
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
        moment: ImagineShotMoment
    ) -> String? {
        guard let gallery else { return nil }
        if let selected = gallery.selectedPath(for: moment),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: selected) {
            return selected
        }
        return gallery.paths(for: moment).last { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    private static func containsHardContinuityBreak(in prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let hardBreakMarkers = [
            "hard cut",
            "cut to",
            "new angle",
            "reverse angle",
            "different location",
            "new location",
            "different time",
            "time jump",
            "jump cut",
            "flashback",
            "wide establishing"
        ]
        return hardBreakMarkers.contains { lower.contains($0) }
    }

    private static func makeOpenMattePlan(input: Input) -> ShotFrameOpenMattePlan {
        let intendedShot = input.cameraShot ?? .medium
        let generatedShot = widerShot(for: intendedShot)
        let motion = cropMotion(cameraMovement: input.cameraMovement, prompt: input.prompt)
        let sourceAspect = aspectRatioValue(input.generatedAspectRatio) ?? (4.0 / 3.0)
        let targetAspect = aspectRatioValue(input.extractionTargetAspectRatio) ?? (16.0 / 9.0)
        let keyframes = cropKeyframes(
            intendedShot: intendedShot,
            motion: motion,
            sourceAspect: sourceAspect,
            targetAspect: targetAspect
        )
        let currentCrop = keyframes.first { $0.moment == input.moment }?.cropRect
            ?? keyframes.first?.cropRect
            ?? CropRect(x: 0.08, y: 0.18, width: 0.84, height: 0.63)

        let generatedShotText = generatedShot?.displayName ?? "wider than the intended crop"
        let intendedShotText = intendedShot.displayName
        let cropSummary = cropSummaryText(currentCrop)
        let promptInstruction = [
            "OPEN-MATTE / CROP-CONTROL CONTRACT:",
            "Render a \(input.generatedAspectRatio) \(input.generatedImageSize) source plate, composed as \(generatedShotText), not as the final crop.",
            "The intended editorial framing is \(intendedShotText), extracted later as \(input.extractionTargetAspectRatio) \(ShotFrameOpenMattePlan.defaultExtractionFrameSize) crops and eventually protected for \(input.finalDeliveryAspectRatio).",
            "The app will simulate camera motion with deterministic crop keyframes (\(motion.displayName)); do not bake a pan, tilt, or zoom blur into the image.",
            "Keep characters, landmarks, and critical action cleanly inside the central crop-safe zone while leaving extra usable environment on all sides for reframing.",
            "Current \(input.moment.rawValue.lowercased()) normalized crop: \(cropSummary)."
        ].joined(separator: " ")

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
        prompt: String
    ) -> ShotFrameCropMotion {
        let lower = prompt.lowercased()
        if lower.contains("tilt up") || lower.contains("pan up") { return .tiltUp }
        if lower.contains("tilt down") || lower.contains("pan down") { return .tiltDown }
        if lower.contains("pan left") { return .panLeft }
        if lower.contains("pan right") { return .panRight }
        if lower.contains("zoom in") || lower.contains("push in") || lower.contains("dolly in") { return .zoomIn }
        if lower.contains("zoom out") || lower.contains("pull back") || lower.contains("dolly out") { return .zoomOut }
        if lower.contains("track") || lower.contains("follow") { return .track }

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
        targetAspect: Double
    ) -> [ShotFrameCropKeyframe] {
        ImagineShotMoment.allCases.map { moment in
            let progress = progressValue(for: moment)
            let baseWidth = cropWidth(for: intendedShot)
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

    private static func cropWidth(for shot: CameraShot) -> Double {
        switch shot {
        case .extremeWide: 0.94
        case .wide: 0.86
        case .medium: 0.72
        case .mediumClose: 0.62
        case .close: 0.50
        case .extremeClose: 0.38
        }
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

    private static func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
