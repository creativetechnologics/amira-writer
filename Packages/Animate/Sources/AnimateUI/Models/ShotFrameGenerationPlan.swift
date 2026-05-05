import Foundation

/// The execution mode for a generated beginning/middle/end shot frame.
///
/// Gemini image editing currently uses the same `generateContent` endpoint as
/// image generation, but the prompt contract is different: an edit request must
/// include a source image and should describe the delta from that source rather
/// than restating the whole frame as if it were a brand-new image.
@available(macOS 26.0, *)
enum ShotFrameGenerationMode: String, Codable, CaseIterable, Sendable, Hashable {
    case generate
    case edit

    var displayName: String {
        switch self {
        case .generate: "Generate"
        case .edit: "Edit"
        }
    }
}

/// Where the continuity source image came from.
@available(macOS 26.0, *)
enum ShotFrameContinuitySource: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case previousFrame = "previous_frame"
    case beginningFrame = "beginning_frame"
    case middleFrame = "middle_frame"
    case previousShotFrame = "previous_shot_frame"
    case storyboardFrame = "storyboard_frame"
    case referenceImage = "reference_image"
    case manualSelection = "manual_selection"

    var displayName: String {
        switch self {
        case .none: "None"
        case .previousFrame: "Previous frame"
        case .beginningFrame: "Beginning frame"
        case .middleFrame: "Middle frame"
        case .previousShotFrame: "Previous shot"
        case .storyboardFrame: "Storyboard"
        case .referenceImage: "Reference image"
        case .manualSelection: "Manual source"
        }
    }
}

/// Why the resolver chose generate vs edit.
@available(macOS 26.0, *)
enum ShotFrameStrategyReason: String, Codable, CaseIterable, Sendable, Hashable {
    case beginningDefaultsToGenerate = "beginning_defaults_to_generate"
    case middleEndPreferEditContinuity = "middle_end_prefer_edit_continuity"
    case sourceImageAvailable = "source_image_available"
    case sourceImageMissing = "source_image_missing"
    case storyboardReferenceAvailable = "storyboard_reference_available"
    case storyboardOverridesScript = "storyboard_overrides_script"
    case scriptStillSuppliesSemantics = "script_still_supplies_semantics"
    case imageIntelligenceReferencesAvailable = "image_intelligence_references_available"
    case manualReferenceImagesAvailable = "manual_reference_images_available"
    case manualOverride = "manual_override"
    case hardContinuityBreak = "hard_continuity_break"
    case safetyFallbackGenerate = "safety_fallback_generate"

    var label: String {
        switch self {
        case .beginningDefaultsToGenerate: "Beginning frame starts the shot"
        case .middleEndPreferEditContinuity: "Middle/end preserve continuity by editing"
        case .sourceImageAvailable: "A generated source image is available"
        case .sourceImageMissing: "No generated source image available"
        case .storyboardReferenceAvailable: "Storyboard drawing is attached"
        case .storyboardOverridesScript: "Storyboard is visual authority"
        case .scriptStillSuppliesSemantics: "Script supplies semantic fallback"
        case .imageIntelligenceReferencesAvailable: "Image Intelligence selected references"
        case .manualReferenceImagesAvailable: "Manual references are attached"
        case .manualOverride: "Manual override"
        case .hardContinuityBreak: "Hard continuity break"
        case .safetyFallbackGenerate: "Generate fallback"
        }
    }
}

/// How strongly non-script visual inputs should dominate the script text.
@available(macOS 26.0, *)
enum ShotFrameOverridePolicy: String, Codable, CaseIterable, Sendable, Hashable {
    case scriptOnly = "script_only"
    case scriptPrimary = "script_primary"
    case storyboardPrimary = "storyboard_primary"
    case storyboardOverridesWhenClear = "storyboard_overrides_when_clear"
    case manualOverride = "manual_override"

    var displayName: String {
        switch self {
        case .scriptOnly: "Script only"
        case .scriptPrimary: "Script primary"
        case .storyboardPrimary: "Storyboard primary"
        case .storyboardOverridesWhenClear: "Storyboard overrides when clear"
        case .manualOverride: "Manual override"
        }
    }
}

@available(macOS 26.0, *)
enum ShotFrameCropMotion: String, Codable, CaseIterable, Sendable, Hashable {
    case hold
    case panLeft = "pan_left"
    case panRight = "pan_right"
    case tiltUp = "tilt_up"
    case tiltDown = "tilt_down"
    case zoomIn = "zoom_in"
    case zoomOut = "zoom_out"
    case track
    case shake

    var displayName: String {
        switch self {
        case .hold: "Hold"
        case .panLeft: "Pan Left"
        case .panRight: "Pan Right"
        case .tiltUp: "Tilt Up"
        case .tiltDown: "Tilt Down"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .track: "Track"
        case .shake: "Shake"
        }
    }
}

@available(macOS 26.0, *)
struct ShotFrameCropKeyframe: Codable, Equatable, Hashable, Sendable {
    var moment: ImagineShotMoment
    /// Normalized crop rectangle within the generated open-matte source image.
    /// Coordinates are top-left origin in source-image space; x/y/width/height
    /// are all 0...1.
    var cropRect: CropRect
    var note: String?

    init(moment: ImagineShotMoment, cropRect: CropRect, note: String? = nil) {
        self.moment = moment
        self.cropRect = cropRect
        self.note = note
    }
}

@available(macOS 26.0, *)
struct ShotFrameOpenMattePlan: Codable, Equatable, Hashable, Sendable {
    static let defaultGeneratedAspectRatio = "16:9"
    static let defaultGeneratedImageSize = "4K"
    static let defaultExtractionTargetAspectRatio = "16:9"
    static let defaultFinalDeliveryAspectRatio = "21:9"
    static let defaultExtractionFrameSize = "1920x1080"

    /// Aspect ratio sent to Gemini for the source plate. Defaults to 16:9 for
    /// direct widescreen framing while still supporting deterministic crop
    /// keyframes and final-delivery protection.
    var generatedAspectRatio: String
    /// Image size sent to Gemini for the source plate. Defaults to 4K so a
    /// 1080p extraction can pan/tilt/zoom without asking the model to perform
    /// the camera move.
    var generatedImageSize: String
    /// Aspect ratio extracted for the video generator.
    var extractionTargetAspectRatio: String
    /// Intended downstream editorial crop.
    var finalDeliveryAspectRatio: String
    var extractionFrameSize: String
    /// The authored/desired crop-language framing (for example Medium).
    var intendedCameraShot: CameraShot?
    /// The wider framing the prompt asks Gemini to render in the open-matte
    /// source plate (for example Wide for an intended Medium crop).
    var generatedCameraShot: CameraShot?
    var cropMotion: ShotFrameCropMotion
    /// Crop for this plan's specific beginning/middle/end frame.
    var cropRect: CropRect
    /// All crop keyframes for this shot so every saved frame sidecar can drive
    /// the same deterministic camera move.
    var cropKeyframes: [ShotFrameCropKeyframe]
    var promptInstruction: String

    init(
        generatedAspectRatio: String = ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
        generatedImageSize: String = ShotFrameOpenMattePlan.defaultGeneratedImageSize,
        extractionTargetAspectRatio: String = ShotFrameOpenMattePlan.defaultExtractionTargetAspectRatio,
        finalDeliveryAspectRatio: String = ShotFrameOpenMattePlan.defaultFinalDeliveryAspectRatio,
        extractionFrameSize: String = ShotFrameOpenMattePlan.defaultExtractionFrameSize,
        intendedCameraShot: CameraShot? = nil,
        generatedCameraShot: CameraShot? = nil,
        cropMotion: ShotFrameCropMotion = .hold,
        cropRect: CropRect,
        cropKeyframes: [ShotFrameCropKeyframe],
        promptInstruction: String
    ) {
        self.generatedAspectRatio = generatedAspectRatio
        self.generatedImageSize = generatedImageSize
        self.extractionTargetAspectRatio = extractionTargetAspectRatio
        self.finalDeliveryAspectRatio = finalDeliveryAspectRatio
        self.extractionFrameSize = extractionFrameSize
        self.intendedCameraShot = intendedCameraShot
        self.generatedCameraShot = generatedCameraShot
        self.cropMotion = cropMotion
        self.cropRect = cropRect
        self.cropKeyframes = cropKeyframes
        self.promptInstruction = promptInstruction
    }
}

@available(macOS 26.0, *)
struct ShotFrameSourceImage: Codable, Equatable, Hashable, Sendable {
    var path: String
    var source: ShotFrameContinuitySource
    var moment: ImagineShotMoment?
    var confidence: Double
    var note: String?

    init(
        path: String,
        source: ShotFrameContinuitySource,
        moment: ImagineShotMoment? = nil,
        confidence: Double = 1.0,
        note: String? = nil
    ) {
        self.path = path
        self.source = source
        self.moment = moment
        self.confidence = confidence
        self.note = note
    }
}

@available(macOS 26.0, *)
struct ShotFrameGenerationDecision: Codable, Equatable, Hashable, Sendable {
    var mode: ShotFrameGenerationMode
    var sourceImage: ShotFrameSourceImage?
    var reasons: [ShotFrameStrategyReason]
    var confidence: Double

    var usesEditPrompt: Bool {
        mode == .edit
    }

    var requiresSourceImage: Bool {
        mode == .edit
    }

    var canExecute: Bool {
        !requiresSourceImage || sourceImage != nil
    }

    init(
        mode: ShotFrameGenerationMode,
        sourceImage: ShotFrameSourceImage? = nil,
        reasons: [ShotFrameStrategyReason] = [],
        confidence: Double = 1.0
    ) {
        self.mode = mode
        self.sourceImage = sourceImage
        self.reasons = reasons
        self.confidence = confidence
    }
}

/// A resolved generation contract for one beginning/middle/end frame.
@available(macOS 26.0, *)
struct ShotFrameGenerationPlan: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var schemaVersion: Int
    var sceneID: UUID
    var shotID: UUID
    var shotIndex: Int
    var moment: ImagineShotMoment
    var decision: ShotFrameGenerationDecision
    var basePrompt: String
    var effectivePrompt: String
    var editInstruction: String?
    var storyboardImagePath: String?
    var storyboardAnalysisPath: String?
    var referenceImagePaths: [String]
    var overridePolicy: ShotFrameOverridePolicy
    var openMattePlan: ShotFrameOpenMattePlan?
    var createdAt: Date

    var mode: ShotFrameGenerationMode { decision.mode }
    var sourceImage: ShotFrameSourceImage? { decision.sourceImage }
    var usesEditPrompt: Bool { decision.usesEditPrompt }
    var requiresSourceImage: Bool { decision.requiresSourceImage }
    var canExecute: Bool { decision.canExecute }

    var executionPrompt: String {
        if usesEditPrompt, let editInstruction, !editInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return editInstruction
        }
        return effectivePrompt
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int,
        moment: ImagineShotMoment,
        decision: ShotFrameGenerationDecision,
        basePrompt: String,
        effectivePrompt: String,
        editInstruction: String? = nil,
        storyboardImagePath: String? = nil,
        storyboardAnalysisPath: String? = nil,
        referenceImagePaths: [String] = [],
        overridePolicy: ShotFrameOverridePolicy = .storyboardOverridesWhenClear,
        openMattePlan: ShotFrameOpenMattePlan? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sceneID = sceneID
        self.shotID = shotID
        self.shotIndex = shotIndex
        self.moment = moment
        self.decision = decision
        self.basePrompt = basePrompt
        self.effectivePrompt = effectivePrompt
        self.editInstruction = editInstruction
        self.storyboardImagePath = storyboardImagePath
        self.storyboardAnalysisPath = storyboardAnalysisPath
        self.referenceImagePaths = referenceImagePaths
        self.overridePolicy = overridePolicy
        self.openMattePlan = openMattePlan
        self.createdAt = createdAt
    }

    static func defaultGenerate(
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int,
        moment: ImagineShotMoment,
        prompt: String,
        storyboardImagePath: String? = nil,
        storyboardAnalysisPath: String? = nil,
        referenceImagePaths: [String] = [],
        openMattePlan: ShotFrameOpenMattePlan? = nil
    ) -> ShotFrameGenerationPlan {
        var reasons: [ShotFrameStrategyReason] = []
        if moment == .beginning {
            reasons.append(.beginningDefaultsToGenerate)
        } else {
            reasons.append(.sourceImageMissing)
            reasons.append(.safetyFallbackGenerate)
        }
        if storyboardImagePath != nil {
            reasons.append(.storyboardReferenceAvailable)
            reasons.append(.storyboardOverridesScript)
        }
        return ShotFrameGenerationPlan(
            sceneID: sceneID,
            shotID: shotID,
            shotIndex: shotIndex,
            moment: moment,
            decision: ShotFrameGenerationDecision(
                mode: .generate,
                reasons: reasons,
                confidence: storyboardImagePath == nil ? 0.72 : 0.82
            ),
            basePrompt: prompt,
            effectivePrompt: prompt,
            storyboardImagePath: storyboardImagePath,
            storyboardAnalysisPath: storyboardAnalysisPath,
            referenceImagePaths: referenceImagePaths,
            openMattePlan: openMattePlan
        )
    }

    static func defaultEdit(
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int,
        moment: ImagineShotMoment,
        prompt: String,
        sourceImage: ShotFrameSourceImage,
        editInstruction: String,
        storyboardImagePath: String? = nil,
        storyboardAnalysisPath: String? = nil,
        referenceImagePaths: [String] = [],
        openMattePlan: ShotFrameOpenMattePlan? = nil
    ) -> ShotFrameGenerationPlan {
        var reasons: [ShotFrameStrategyReason] = [
            .middleEndPreferEditContinuity,
            .sourceImageAvailable
        ]
        if storyboardImagePath != nil {
            reasons.append(.storyboardReferenceAvailable)
            reasons.append(.storyboardOverridesScript)
        }
        return ShotFrameGenerationPlan(
            sceneID: sceneID,
            shotID: shotID,
            shotIndex: shotIndex,
            moment: moment,
            decision: ShotFrameGenerationDecision(
                mode: .edit,
                sourceImage: sourceImage,
                reasons: reasons,
                confidence: 0.9
            ),
            basePrompt: prompt,
            effectivePrompt: editInstruction,
            editInstruction: editInstruction,
            storyboardImagePath: storyboardImagePath,
            storyboardAnalysisPath: storyboardAnalysisPath,
            referenceImagePaths: referenceImagePaths,
            openMattePlan: openMattePlan
        )
    }
}

@available(macOS 26.0, *)
struct ShotFrameGenerationPlanSet: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var schemaVersion: Int
    var sceneID: UUID
    var shotID: UUID
    var plans: [ShotFrameGenerationPlan]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        sceneID: UUID,
        shotID: UUID,
        plans: [ShotFrameGenerationPlan],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sceneID = sceneID
        self.shotID = shotID
        self.plans = plans
        self.createdAt = createdAt
    }

    func plan(for moment: ImagineShotMoment) -> ShotFrameGenerationPlan? {
        plans.first { $0.moment == moment }
    }
}
