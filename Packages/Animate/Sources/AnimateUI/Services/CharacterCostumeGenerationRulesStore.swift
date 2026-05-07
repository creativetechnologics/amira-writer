import Foundation
import ProjectKit

enum CharacterCostumePromptSection: String, Codable, Sendable, Hashable, CaseIterable {
    case task
    case sequence
    case identity
    case notes
    case world
    case instructions
    case style
    case composition
    case negative
}

struct CharacterCostumePromptTemplates: Codable, Sendable, Hashable {
    var taskLineTemplate: String
    var singleImageSequenceLine: String
    var multiImageSequenceLineTemplate: String
    var identityLine: String
    var notesLineTemplate: String
    var worldLineTemplate: String
    var instructionsLineTemplate: String
    var defaultStyleLine: String
    var styleLineTemplate: String
    var compositionLine: String
    var negativeLine: String

    static let `default` = CharacterCostumePromptTemplates(
        taskLineTemplate: "Generate an animated character costume study image.",
        singleImageSequenceLine: "Create one clear costume-study variation.",
        multiImageSequenceLineTemplate: "Variation {imageIndex} of {imageCount}: keep identity and wardrobe continuity while varying secondary costume details.",
        identityLine: "Preserve exact identity from references: face structure, age read, skin tone, hair, proportions, and silhouette.",
        notesLineTemplate: "Authoritative character notes: {characterPromptNotes}",
        worldLineTemplate: "World grounding: {worldSummary}.",
        instructionsLineTemplate: "Additional instructions: {userPrompt}",
        defaultStyleLine: "Style: mature 2D anime feature-film realism, clean elegant linework, restrained cel shading, production-ready costume readability, serious adult dramatic tone.",
        styleLineTemplate: "Style: {style}",
        compositionLine: "Composition: full-body or near-full-body costume study from head to footwear, centered, clear lighting, uncluttered neutral background unless explicitly overridden.",
        negativeLine: "Negative constraints: no extra characters, no labels/text/watermarks, no distorted anatomy, no broken hands, no photorealistic 3D render, no chibi/cute stylization, no generic fantasy armor, no tactical-hero exaggeration."
    )
}

struct CharacterCostumePromptProtocol: Codable, Sendable, Hashable {
    var sectionOrder: [CharacterCostumePromptSection]
    var templates: CharacterCostumePromptTemplates

    static let `default` = CharacterCostumePromptProtocol(
        sectionOrder: [.task, .sequence, .identity, .notes, .world, .instructions, .style, .composition, .negative],
        templates: .default
    )
}

struct CharacterCostumeGenerationRules: Codable, Sendable, Hashable {
    var schemaVersion: Int = 1

    /// Filter out references whose XMP sidecar marks them rejected.
    var dropRejectedReferences: Bool = true

    /// If true, any rejected path in an explicit API list fails the request.
    var failExplicitWhenAnyRejected: Bool = true

    /// If true, an explicit list that resolves to no usable references fails.
    var failExplicitWhenAllRejectedOrMissing: Bool = true

    /// Hard cap for explicit reference paths from API calls.
    var maxExplicitReferenceCount: Int = 4

    /// Hard cap for automatically discovered reference paths.
    var maxAutoReferenceCount: Int = 8

    /// Automatic reference source toggles.
    var includeApprovedHeadTurnaroundSheet: Bool = true
    var includeApprovedCostumeSheet: Bool = true
    var includeApprovedMasterSheet: Bool = true
    var includeCharacterReferenceImages: Bool = true
    var includeInspirationReferenceImage: Bool = true
    var includeCuratedInspirationImages: Bool = true
    var includeProfileImage: Bool = true
    var includeShotReferenceImages: Bool = false
    var includeRecentAnimatedImages: Bool = false
    var promptProtocol: CharacterCostumePromptProtocol = .default

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case dropRejectedReferences
        case failExplicitWhenAnyRejected
        case failExplicitWhenAllRejectedOrMissing
        case maxExplicitReferenceCount
        case maxAutoReferenceCount
        case includeApprovedHeadTurnaroundSheet
        case includeApprovedCostumeSheet
        case includeApprovedMasterSheet
        case includeCharacterReferenceImages
        case includeInspirationReferenceImage
        case includeCuratedInspirationImages
        case includeProfileImage
        case includeShotReferenceImages
        case includeRecentAnimatedImages
        case promptProtocol
    }

    static let `default` = CharacterCostumeGenerationRules()

    init(
        schemaVersion: Int = 1,
        dropRejectedReferences: Bool = true,
        failExplicitWhenAnyRejected: Bool = true,
        failExplicitWhenAllRejectedOrMissing: Bool = true,
        maxExplicitReferenceCount: Int = 4,
        maxAutoReferenceCount: Int = 8,
        includeApprovedHeadTurnaroundSheet: Bool = true,
        includeApprovedCostumeSheet: Bool = true,
        includeApprovedMasterSheet: Bool = true,
        includeCharacterReferenceImages: Bool = true,
        includeInspirationReferenceImage: Bool = true,
        includeCuratedInspirationImages: Bool = true,
        includeProfileImage: Bool = true,
        includeShotReferenceImages: Bool = false,
        includeRecentAnimatedImages: Bool = false,
        promptProtocol: CharacterCostumePromptProtocol = .default
    ) {
        self.schemaVersion = schemaVersion
        self.dropRejectedReferences = dropRejectedReferences
        self.failExplicitWhenAnyRejected = failExplicitWhenAnyRejected
        self.failExplicitWhenAllRejectedOrMissing = failExplicitWhenAllRejectedOrMissing
        self.maxExplicitReferenceCount = maxExplicitReferenceCount
        self.maxAutoReferenceCount = maxAutoReferenceCount
        self.includeApprovedHeadTurnaroundSheet = includeApprovedHeadTurnaroundSheet
        self.includeApprovedCostumeSheet = includeApprovedCostumeSheet
        self.includeApprovedMasterSheet = includeApprovedMasterSheet
        self.includeCharacterReferenceImages = includeCharacterReferenceImages
        self.includeInspirationReferenceImage = includeInspirationReferenceImage
        self.includeCuratedInspirationImages = includeCuratedInspirationImages
        self.includeProfileImage = includeProfileImage
        self.includeShotReferenceImages = includeShotReferenceImages
        self.includeRecentAnimatedImages = includeRecentAnimatedImages
        self.promptProtocol = promptProtocol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            dropRejectedReferences: try container.decodeIfPresent(Bool.self, forKey: .dropRejectedReferences) ?? true,
            failExplicitWhenAnyRejected: try container.decodeIfPresent(Bool.self, forKey: .failExplicitWhenAnyRejected) ?? true,
            failExplicitWhenAllRejectedOrMissing: try container.decodeIfPresent(Bool.self, forKey: .failExplicitWhenAllRejectedOrMissing) ?? true,
            maxExplicitReferenceCount: try container.decodeIfPresent(Int.self, forKey: .maxExplicitReferenceCount) ?? 4,
            maxAutoReferenceCount: try container.decodeIfPresent(Int.self, forKey: .maxAutoReferenceCount) ?? 8,
            includeApprovedHeadTurnaroundSheet: try container.decodeIfPresent(Bool.self, forKey: .includeApprovedHeadTurnaroundSheet) ?? true,
            includeApprovedCostumeSheet: try container.decodeIfPresent(Bool.self, forKey: .includeApprovedCostumeSheet) ?? true,
            includeApprovedMasterSheet: try container.decodeIfPresent(Bool.self, forKey: .includeApprovedMasterSheet) ?? true,
            includeCharacterReferenceImages: try container.decodeIfPresent(Bool.self, forKey: .includeCharacterReferenceImages) ?? true,
            includeInspirationReferenceImage: try container.decodeIfPresent(Bool.self, forKey: .includeInspirationReferenceImage) ?? true,
            includeCuratedInspirationImages: try container.decodeIfPresent(Bool.self, forKey: .includeCuratedInspirationImages) ?? true,
            includeProfileImage: try container.decodeIfPresent(Bool.self, forKey: .includeProfileImage) ?? true,
            includeShotReferenceImages: try container.decodeIfPresent(Bool.self, forKey: .includeShotReferenceImages) ?? false,
            includeRecentAnimatedImages: try container.decodeIfPresent(Bool.self, forKey: .includeRecentAnimatedImages) ?? false,
            promptProtocol: try container.decodeIfPresent(CharacterCostumePromptProtocol.self, forKey: .promptProtocol) ?? .default
        )
    }

    func normalized() -> CharacterCostumeGenerationRules {
        var copy = self
        copy.schemaVersion = max(copy.schemaVersion, 1)
        copy.maxExplicitReferenceCount = min(max(copy.maxExplicitReferenceCount, 1), 24)
        copy.maxAutoReferenceCount = min(max(copy.maxAutoReferenceCount, 1), 24)
        if copy.promptProtocol.sectionOrder.isEmpty {
            copy.promptProtocol.sectionOrder = CharacterCostumePromptProtocol.default.sectionOrder
        }
        return copy
    }
}

enum CharacterCostumeGenerationRulesStore {
    static func load(projectRoot: URL) -> CharacterCostumeGenerationRules {
        let url = ProjectPaths(root: projectRoot).characterCostumeGenerationRulesJSON
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CharacterCostumeGenerationRules.self, from: data) else {
            let fallback = CharacterCostumeGenerationRules.default.normalized()
            try? save(fallback, projectRoot: projectRoot)
            return fallback
        }
        let normalized = decoded.normalized()
        if normalized != decoded {
            try? save(normalized, projectRoot: projectRoot)
        }
        return normalized
    }

    static func save(_ rules: CharacterCostumeGenerationRules, projectRoot: URL) throws {
        let url = ProjectPaths(root: projectRoot).characterCostumeGenerationRulesJSON
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules.normalized())
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
