import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum ShotVisualPromptSection: String, Codable, Sendable, Hashable, CaseIterable {
    case action
    case environment
    case camera
    case lighting
    case characters
    case style
    case guardrail
    case review
    case cleanOutput
}

@available(macOS 26.0, *)
enum ShotEnvironmentSourceMode: String, Codable, Sendable, Hashable {
    case regionOnly = "region_only"
    case regionThenMaterials = "region_then_materials"
}

@available(macOS 26.0, *)
struct ShotVisualPromptTemplates: Codable, Sendable, Hashable {
    var fallbackActionText: String
    var fallbackRegionText: String
    var fallbackLightingText: String
    var minimalVisualToneText: String
    var fallbackVisualToneText: String
    var cameraLineTemplate: String
    var lightingLineTemplate: String
    var reviewFeedbackLineTemplate: String
    var cleanOutputWhenGuidesForbidden: String
    var cleanOutputDefault: String
    var defaultGuardrails: [String]

    static let `default` = ShotVisualPromptTemplates(
        fallbackActionText: "A single clear visual moment grounded in the attached references.",
        fallbackRegionText: "A high mountain valley with rugged slopes and a winding river road.",
        fallbackLightingText: "Natural light with coherent time-of-day continuity.",
        minimalVisualToneText: "Grounded mature 2D animated frame; restrained adult anime style; controlled thin linework; lightly simplified forms; serious cinematic staging; natural proportions; all important background and character details in focus; calm atmospheric depth; no text or graphic overlays.",
        fallbackVisualToneText: "Grounded mature 2D animated visual tone.",
        cameraLineTemplate: "Camera framing and optics: {camera}.",
        lightingLineTemplate: "Lighting and atmosphere: {lighting}.",
        reviewFeedbackLineTemplate: "Apply these visual corrections from prior feedback: {feedback}",
        cleanOutputWhenGuidesForbidden: "No text, captions, logos, watermarks, guide marks, white frame lines, crop boxes, borders, or interface overlays.",
        cleanOutputDefault: "No text, captions, logos, watermarks, borders, or graphic overlays.",
        defaultGuardrails: [
            "No text overlays, no captions, no logos, no collage panels, no guide marks, no border lines.",
            "Use explicit visual details only; do not rely on story, project, scene, or character-name context."
        ]
    )
}

@available(macOS 26.0, *)
struct ShotVisualPromptProtocol: Codable, Sendable, Hashable {
    var sectionOrder: [ShotVisualPromptSection]
    var environmentSourceMode: ShotEnvironmentSourceMode
    var characterSentenceLimit: Int
    var templates: ShotVisualPromptTemplates

    static let `default` = ShotVisualPromptProtocol(
        sectionOrder: [.action, .environment, .camera, .lighting, .characters, .style, .guardrail, .review, .cleanOutput],
        environmentSourceMode: .regionOnly,
        characterSentenceLimit: 3,
        templates: .default
    )
}

@available(macOS 26.0, *)
enum ShotFramePromptSection: String, Codable, Sendable, Hashable, CaseIterable {
    case basePrompt
    case openMatteInstruction
    case continuitySource
    case noRedesign
    case momentProgression
    case storyboardGuidance
    case returnOneImage
}

@available(macOS 26.0, *)
struct ShotFrameMotionKeywordTemplates: Codable, Sendable, Hashable {
    var tiltUp: [String]
    var tiltDown: [String]
    var panLeft: [String]
    var panRight: [String]
    var zoomIn: [String]
    var zoomOut: [String]
    var track: [String]

    static let `default` = ShotFrameMotionKeywordTemplates(
        tiltUp: ["tilt up", "pan up"],
        tiltDown: ["tilt down", "pan down"],
        panLeft: ["pan left"],
        panRight: ["pan right"],
        zoomIn: ["zoom in", "push in", "dolly in"],
        zoomOut: ["zoom out", "pull back", "dolly out"],
        track: ["track", "follow"]
    )

    func keywords(for motion: ShotFrameCropMotion) -> [String] {
        switch motion {
        case .tiltUp: return tiltUp
        case .tiltDown: return tiltDown
        case .panLeft: return panLeft
        case .panRight: return panRight
        case .zoomIn: return zoomIn
        case .zoomOut: return zoomOut
        case .track: return track
        case .hold, .shake: return []
        }
    }
}

@available(macOS 26.0, *)
struct ShotOpenMattePromptTemplates: Codable, Sendable, Hashable {
    var detailedLine1Template: String
    var detailedLine2Template: String
    var detailedLine3Template: String
    var detailedLine4Template: String
    var compactLine1Template: String
    var compactLine2Template: String
    var compactGuidesForbiddenLine: String

    static let `default` = ShotOpenMattePromptTemplates(
        detailedLine1Template: "Compose a full-bleed {generatedAspectRatio} {generatedImageSize} image with extra environment around the action for later reframing.",
        detailedLine2Template: "Keep the composition readable as {generatedShot}, with the intended final framing landing near {intendedShot}.",
        detailedLine3Template: "Preserve natural still-image clarity; avoid stylized pan, tilt, or zoom blur.",
        detailedLine4Template: "Current protected crop region for this moment: {cropSummary}.",
        compactLine1Template: "Compose a full-bleed {generatedAspectRatio} {generatedImageSize} image with extra environment for later reframing.",
        compactLine2Template: "Preserve natural still-image clarity without stylized motion blur.",
        compactGuidesForbiddenLine: "Keep the composition clean and free of interface-style marks."
    )
}

@available(macOS 26.0, *)
struct ShotFramePromptTemplates: Codable, Sendable, Hashable {
    var storyboardGuidanceLine: String
    var continuitySourceLineTemplate: String
    var noRedesignLine: String
    var returnOneImageLine: String
    var momentProgressionBeginning: String
    var momentProgressionMiddle: String
    var momentProgressionEnd: String
    var openMatte: ShotOpenMattePromptTemplates

    static let `default` = ShotFramePromptTemplates(
        storyboardGuidanceLine: "If a storyboard reference image is attached, use it only for composition guidance.",
        continuitySourceLineTemplate: "Use attached reference images as visual identity anchors ({source}) for geography, camera direction, wardrobe, accessories, and character identity.",
        noRedesignLine: "Do not redesign the location or switch to a reverse angle.",
        returnOneImageLine: "Return one image.",
        momentProgressionBeginning: "",
        momentProgressionMiddle: "",
        momentProgressionEnd: "",
        openMatte: .default
    )
}

@available(macOS 26.0, *)
struct ShotFramePromptProtocol: Codable, Sendable, Hashable {
    var generationOrder: [ShotFramePromptSection]
    var editOrder: [ShotFramePromptSection]
    var templates: ShotFramePromptTemplates
    var hardContinuityBreakMarkers: [String]
    var motionKeywords: ShotFrameMotionKeywordTemplates
    var cropWidthByIntendedShot: [String: Double]

    enum CodingKeys: String, CodingKey {
        case generationOrder
        case editOrder
        case templates
        case hardContinuityBreakMarkers
        case motionKeywords
        case cropWidthByIntendedShot
    }

    init(
        generationOrder: [ShotFramePromptSection] = ShotFramePromptProtocol.default.generationOrder,
        editOrder: [ShotFramePromptSection] = ShotFramePromptProtocol.default.editOrder,
        templates: ShotFramePromptTemplates = ShotFramePromptProtocol.default.templates,
        hardContinuityBreakMarkers: [String] = ShotFramePromptProtocol.default.hardContinuityBreakMarkers,
        motionKeywords: ShotFrameMotionKeywordTemplates = ShotFramePromptProtocol.default.motionKeywords,
        cropWidthByIntendedShot: [String: Double] = ShotFramePromptProtocol.default.cropWidthByIntendedShot
    ) {
        self.generationOrder = generationOrder
        self.editOrder = editOrder
        self.templates = templates
        self.hardContinuityBreakMarkers = hardContinuityBreakMarkers
        self.motionKeywords = motionKeywords
        self.cropWidthByIntendedShot = cropWidthByIntendedShot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generationOrder: try container.decodeIfPresent([ShotFramePromptSection].self, forKey: .generationOrder) ?? ShotFramePromptProtocol.default.generationOrder,
            editOrder: try container.decodeIfPresent([ShotFramePromptSection].self, forKey: .editOrder) ?? ShotFramePromptProtocol.default.editOrder,
            templates: try container.decodeIfPresent(ShotFramePromptTemplates.self, forKey: .templates) ?? ShotFramePromptProtocol.default.templates,
            hardContinuityBreakMarkers: try container.decodeIfPresent([String].self, forKey: .hardContinuityBreakMarkers) ?? ShotFramePromptProtocol.default.hardContinuityBreakMarkers,
            motionKeywords: try container.decodeIfPresent(ShotFrameMotionKeywordTemplates.self, forKey: .motionKeywords) ?? ShotFramePromptProtocol.default.motionKeywords,
            cropWidthByIntendedShot: try container.decodeIfPresent([String: Double].self, forKey: .cropWidthByIntendedShot) ?? ShotFramePromptProtocol.default.cropWidthByIntendedShot
        )
    }

    static let `default` = ShotFramePromptProtocol(
        generationOrder: [.basePrompt, .openMatteInstruction, .momentProgression, .storyboardGuidance],
        editOrder: [.basePrompt, .openMatteInstruction, .continuitySource, .noRedesign, .momentProgression, .storyboardGuidance, .returnOneImage],
        templates: .default,
        hardContinuityBreakMarkers: [
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
        ],
        motionKeywords: .default,
        cropWidthByIntendedShot: [
            CameraShot.extremeWide.rawValue: 0.94,
            CameraShot.wide.rawValue: 0.86,
            CameraShot.medium.rawValue: 0.72,
            CameraShot.mediumClose.rawValue: 0.62,
            CameraShot.close.rawValue: 0.50,
            CameraShot.extremeClose.rawValue: 0.38
        ]
    )
}

@available(macOS 26.0, *)
struct ShotPromptSanitization: Codable, Sendable, Hashable {
    var seededScriptLinePattern: String
    var additionalStripPatterns: [String]
    var stripBracketedSpans: Bool
    var stripResidualSquareBrackets: Bool
    var collapseWhitespace: Bool
    var firstSentenceDelimiters: [String]
    var replaceCharacterNamesWith: String
    var includeNameFragments: Bool
    var minimumNameFragmentLength: Int

    static let `default` = ShotPromptSanitization(
        seededScriptLinePattern: #"(?i)seeded\s+from\s+script\s+line\s*\d+\s*[·:,\-\]]*\s*"#,
        additionalStripPatterns: [],
        stripBracketedSpans: true,
        stripResidualSquareBrackets: true,
        collapseWhitespace: true,
        firstSentenceDelimiters: [". ", ".\n", "?", "!", ";"],
        replaceCharacterNamesWith: "the subject",
        includeNameFragments: true,
        minimumNameFragmentLength: 3
    )
}

@available(macOS 26.0, *)
struct ShotPromptProtocolSettings: Codable, Sendable, Hashable {
    var schemaVersion: Int
    var sanitization: ShotPromptSanitization
    var visualSpec: ShotVisualPromptProtocol
    var framePlan: ShotFramePromptProtocol

    init(
        schemaVersion: Int = 1,
        sanitization: ShotPromptSanitization = .default,
        visualSpec: ShotVisualPromptProtocol = .default,
        framePlan: ShotFramePromptProtocol = .default
    ) {
        self.schemaVersion = schemaVersion
        self.sanitization = sanitization
        self.visualSpec = visualSpec
        self.framePlan = framePlan
    }

    static let `default` = ShotPromptProtocolSettings()

    func normalized() -> ShotPromptProtocolSettings {
        var copy = self
        copy.schemaVersion = max(copy.schemaVersion, 1)

        let replacement = copy.sanitization.replaceCharacterNamesWith.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sanitization.replaceCharacterNamesWith = replacement.isEmpty ? "the subject" : replacement
        copy.sanitization.minimumNameFragmentLength = min(max(copy.sanitization.minimumNameFragmentLength, 1), 24)
        let delimiters = copy.sanitization.firstSentenceDelimiters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copy.sanitization.firstSentenceDelimiters = delimiters.isEmpty
            ? ShotPromptSanitization.default.firstSentenceDelimiters
            : delimiters

        copy.visualSpec.characterSentenceLimit = min(max(copy.visualSpec.characterSentenceLimit, 1), 10)
        if copy.visualSpec.sectionOrder.isEmpty {
            copy.visualSpec.sectionOrder = ShotVisualPromptProtocol.default.sectionOrder
        }
        if copy.visualSpec.templates.defaultGuardrails.isEmpty {
            copy.visualSpec.templates.defaultGuardrails = ShotVisualPromptTemplates.default.defaultGuardrails
        }

        if copy.framePlan.generationOrder.isEmpty {
            copy.framePlan.generationOrder = ShotFramePromptProtocol.default.generationOrder
        }
        if copy.framePlan.editOrder.isEmpty {
            copy.framePlan.editOrder = ShotFramePromptProtocol.default.editOrder
        }
        let normalizedMarkers = copy.framePlan.hardContinuityBreakMarkers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        copy.framePlan.hardContinuityBreakMarkers = normalizedMarkers.isEmpty
            ? ShotFramePromptProtocol.default.hardContinuityBreakMarkers
            : Array(Set(normalizedMarkers)).sorted()

        copy.framePlan.motionKeywords = normalizedMotionKeywords(copy.framePlan.motionKeywords)
        copy.framePlan.cropWidthByIntendedShot = normalizedCropWidths(copy.framePlan.cropWidthByIntendedShot)
        return copy
    }

    private func normalizedMotionKeywords(_ value: ShotFrameMotionKeywordTemplates) -> ShotFrameMotionKeywordTemplates {
        func normalizedKeywords(_ keywords: [String], fallback: [String]) -> [String] {
            let cleaned = keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            if cleaned.isEmpty { return fallback }
            return Array(Set(cleaned)).sorted()
        }

        return ShotFrameMotionKeywordTemplates(
            tiltUp: normalizedKeywords(value.tiltUp, fallback: ShotFrameMotionKeywordTemplates.default.tiltUp),
            tiltDown: normalizedKeywords(value.tiltDown, fallback: ShotFrameMotionKeywordTemplates.default.tiltDown),
            panLeft: normalizedKeywords(value.panLeft, fallback: ShotFrameMotionKeywordTemplates.default.panLeft),
            panRight: normalizedKeywords(value.panRight, fallback: ShotFrameMotionKeywordTemplates.default.panRight),
            zoomIn: normalizedKeywords(value.zoomIn, fallback: ShotFrameMotionKeywordTemplates.default.zoomIn),
            zoomOut: normalizedKeywords(value.zoomOut, fallback: ShotFrameMotionKeywordTemplates.default.zoomOut),
            track: normalizedKeywords(value.track, fallback: ShotFrameMotionKeywordTemplates.default.track)
        )
    }

    private func normalizedCropWidths(_ value: [String: Double]) -> [String: Double] {
        var merged = ShotFramePromptProtocol.default.cropWidthByIntendedShot
        for (rawKey, rawWidth) in value {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            merged[key] = min(max(rawWidth, 0.20), 0.98)
        }
        return merged
    }
}

@available(macOS 26.0, *)
enum ShotPromptProtocolStore {
    static func load(projectRoot: URL) -> ShotPromptProtocolSettings {
        let url = ProjectPaths(root: projectRoot).shotPromptProtocolSettingsJSON
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONCoders.makeDecoder().decode(ShotPromptProtocolSettings.self, from: data) else {
            let fallback = ShotPromptProtocolSettings.default.normalized()
            try? save(fallback, projectRoot: projectRoot)
            return fallback
        }
        let normalized = decoded.normalized()
        if normalized != decoded {
            try? save(normalized, projectRoot: projectRoot)
        }
        return normalized
    }

    static func save(_ settings: ShotPromptProtocolSettings, projectRoot: URL) throws {
        let url = ProjectPaths(root: projectRoot).shotPromptProtocolSettingsJSON
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.normalized())
        try data.write(to: url, options: .atomic)
    }

    static func applyTemplate(_ template: String, values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
