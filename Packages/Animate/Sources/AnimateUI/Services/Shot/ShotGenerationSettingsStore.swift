import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ShotGenerationSettings: Codable, Sendable, Hashable {
    var schemaVersion: Int

    /// Open-matte source plate defaults for scene-shot generation.
    var generatedAspectRatio: String
    var generatedImageSize: String
    var extractionTargetAspectRatio: String
    var finalDeliveryAspectRatio: String

    /// Reference-contract selection policy.
    var maxReferenceCount: Int
    var roleQuotas: [ReferenceRole: Int]
    /// When true, only images explicitly liked/picked (thumbs-up) are eligible
    /// for automatic reference selection.
    var requirePickedReferences: Bool
    /// When true, semantic selector enforces spatial context matching between
    /// shot intent and candidate references (inside_town vs outside_town).
    var enforceSpatialContext: Bool
    var requireRatedReferences: Bool
    var dropRejectedReferences: Bool
    /// Minimum accepted sidecar rating (0-5). When > 0 and
    /// `requireRatedReferences` is true, unrated items are excluded.
    var minimumReferenceRating: Int

    /// Prompt behavior controls. Keep shot-frame prompts lean by default so
    /// scene generation doesn't inherit unrelated review chatter.
    var useMinimalShotPrompts: Bool
    var includeReviewFeedbackInShotPrompts: Bool
    var includeOpenMatteCropContractText: Bool
    var forbidVisibleFrameGuides: Bool
    var useLLMShotPromptCompiler: Bool
    var llmShotPromptProvider: SupplementalLLMProvider
    var llmShotPromptModel: String

    init(
        schemaVersion: Int = 1,
        generatedAspectRatio: String = ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
        generatedImageSize: String = ShotFrameOpenMattePlan.defaultGeneratedImageSize,
        extractionTargetAspectRatio: String = ShotFrameOpenMattePlan.defaultExtractionTargetAspectRatio,
        finalDeliveryAspectRatio: String = ShotFrameOpenMattePlan.defaultFinalDeliveryAspectRatio,
        maxReferenceCount: Int = 8,
        roleQuotas: [ReferenceRole: Int] = ReferenceContract.defaultRoleQuotas,
        requirePickedReferences: Bool = true,
        enforceSpatialContext: Bool = true,
        requireRatedReferences: Bool = false,
        dropRejectedReferences: Bool = true,
        minimumReferenceRating: Int = 1,
        useMinimalShotPrompts: Bool = true,
        includeReviewFeedbackInShotPrompts: Bool = false,
        includeOpenMatteCropContractText: Bool = false,
        forbidVisibleFrameGuides: Bool = true,
        useLLMShotPromptCompiler: Bool = false,
        llmShotPromptProvider: SupplementalLLMProvider = .vertexGemini,
        llmShotPromptModel: String = SupplementalLLMProvider.vertexGemini.defaultModel
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAspectRatio = generatedAspectRatio
        self.generatedImageSize = generatedImageSize
        self.extractionTargetAspectRatio = extractionTargetAspectRatio
        self.finalDeliveryAspectRatio = finalDeliveryAspectRatio
        self.maxReferenceCount = maxReferenceCount
        self.roleQuotas = roleQuotas
        self.requirePickedReferences = requirePickedReferences
        self.enforceSpatialContext = enforceSpatialContext
        self.requireRatedReferences = requireRatedReferences
        self.dropRejectedReferences = dropRejectedReferences
        self.minimumReferenceRating = minimumReferenceRating
        self.useMinimalShotPrompts = useMinimalShotPrompts
        self.includeReviewFeedbackInShotPrompts = includeReviewFeedbackInShotPrompts
        self.includeOpenMatteCropContractText = includeOpenMatteCropContractText
        self.forbidVisibleFrameGuides = forbidVisibleFrameGuides
        self.useLLMShotPromptCompiler = useLLMShotPromptCompiler
        self.llmShotPromptProvider = llmShotPromptProvider
        self.llmShotPromptModel = llmShotPromptModel
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAspectRatio
        case generatedImageSize
        case extractionTargetAspectRatio
        case finalDeliveryAspectRatio
        case maxReferenceCount
        case roleQuotas
        case requirePickedReferences
        case enforceSpatialContext
        case requireRatedReferences
        case dropRejectedReferences
        case minimumReferenceRating
        case useMinimalShotPrompts
        case includeReviewFeedbackInShotPrompts
        case includeOpenMatteCropContractText
        case forbidVisibleFrameGuides
        case useLLMShotPromptCompiler
        case llmShotPromptProvider
        case llmShotPromptModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            generatedAspectRatio: try container.decodeIfPresent(String.self, forKey: .generatedAspectRatio) ?? ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
            generatedImageSize: try container.decodeIfPresent(String.self, forKey: .generatedImageSize) ?? ShotFrameOpenMattePlan.defaultGeneratedImageSize,
            extractionTargetAspectRatio: try container.decodeIfPresent(String.self, forKey: .extractionTargetAspectRatio) ?? ShotFrameOpenMattePlan.defaultExtractionTargetAspectRatio,
            finalDeliveryAspectRatio: try container.decodeIfPresent(String.self, forKey: .finalDeliveryAspectRatio) ?? ShotFrameOpenMattePlan.defaultFinalDeliveryAspectRatio,
            maxReferenceCount: try container.decodeIfPresent(Int.self, forKey: .maxReferenceCount) ?? 8,
            roleQuotas: try container.decodeIfPresent([ReferenceRole: Int].self, forKey: .roleQuotas) ?? ReferenceContract.defaultRoleQuotas,
            requirePickedReferences: try container.decodeIfPresent(Bool.self, forKey: .requirePickedReferences) ?? true,
            enforceSpatialContext: try container.decodeIfPresent(Bool.self, forKey: .enforceSpatialContext) ?? true,
            requireRatedReferences: try container.decodeIfPresent(Bool.self, forKey: .requireRatedReferences) ?? false,
            dropRejectedReferences: try container.decodeIfPresent(Bool.self, forKey: .dropRejectedReferences) ?? true,
            minimumReferenceRating: try container.decodeIfPresent(Int.self, forKey: .minimumReferenceRating) ?? 1,
            useMinimalShotPrompts: try container.decodeIfPresent(Bool.self, forKey: .useMinimalShotPrompts) ?? true,
            includeReviewFeedbackInShotPrompts: try container.decodeIfPresent(Bool.self, forKey: .includeReviewFeedbackInShotPrompts) ?? false,
            includeOpenMatteCropContractText: try container.decodeIfPresent(Bool.self, forKey: .includeOpenMatteCropContractText) ?? false,
            forbidVisibleFrameGuides: try container.decodeIfPresent(Bool.self, forKey: .forbidVisibleFrameGuides) ?? true,
            useLLMShotPromptCompiler: try container.decodeIfPresent(Bool.self, forKey: .useLLMShotPromptCompiler) ?? false,
            llmShotPromptProvider: try container.decodeIfPresent(SupplementalLLMProvider.self, forKey: .llmShotPromptProvider) ?? .vertexGemini,
            llmShotPromptModel: try container.decodeIfPresent(String.self, forKey: .llmShotPromptModel) ?? SupplementalLLMProvider.vertexGemini.defaultModel
        )
    }

    static let `default` = ShotGenerationSettings()

    func normalized() -> ShotGenerationSettings {
        var copy = self
        copy.schemaVersion = max(copy.schemaVersion, 1)

        let trimmedGeneratedAspect = copy.generatedAspectRatio.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.generatedAspectRatio = trimmedGeneratedAspect.isEmpty
            ? ShotFrameOpenMattePlan.defaultGeneratedAspectRatio
            : trimmedGeneratedAspect

        let trimmedImageSize = copy.generatedImageSize.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.generatedImageSize = trimmedImageSize.isEmpty
            ? ShotFrameOpenMattePlan.defaultGeneratedImageSize
            : trimmedImageSize

        let trimmedExtractionAspect = copy.extractionTargetAspectRatio.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.extractionTargetAspectRatio = trimmedExtractionAspect.isEmpty
            ? ShotFrameOpenMattePlan.defaultExtractionTargetAspectRatio
            : trimmedExtractionAspect

        let trimmedFinalAspect = copy.finalDeliveryAspectRatio.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.finalDeliveryAspectRatio = trimmedFinalAspect.isEmpty
            ? ShotFrameOpenMattePlan.defaultFinalDeliveryAspectRatio
            : trimmedFinalAspect

        copy.maxReferenceCount = min(max(copy.maxReferenceCount, 1), 24)
        copy.minimumReferenceRating = min(max(copy.minimumReferenceRating, 0), 5)
        if copy.roleQuotas.isEmpty {
            copy.roleQuotas = ReferenceContract.defaultRoleQuotas
        } else {
            copy.roleQuotas = copy.roleQuotas.mapValues { min(max($0, 0), 24) }
        }
        let llmModel = copy.llmShotPromptModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.llmShotPromptModel = llmModel.isEmpty ? copy.llmShotPromptProvider.defaultModel : llmModel
        // Keep these booleans as-is; normalize only numeric/text inputs.
        return copy
    }
}

@available(macOS 26.0, *)
enum ShotGenerationSettingsStore {
    static func load(projectRoot: URL) -> ShotGenerationSettings {
        let url = ProjectPaths(root: projectRoot).shotGenerationSettingsJSON
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONCoders.makeDecoder().decode(ShotGenerationSettings.self, from: data) else {
            let fallback = ShotGenerationSettings.default.normalized()
            try? save(fallback, projectRoot: projectRoot)
            return fallback
        }
        let normalized = decoded.normalized()
        if normalized != decoded {
            try? save(normalized, projectRoot: projectRoot)
        }
        return normalized
    }

    static func save(_ settings: ShotGenerationSettings, projectRoot: URL) throws {
        let url = ProjectPaths(root: projectRoot).shotGenerationSettingsJSON
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.normalized())
        try data.write(to: url, options: .atomic)
    }
}
