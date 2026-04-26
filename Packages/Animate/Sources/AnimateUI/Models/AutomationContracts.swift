import Foundation

@available(macOS 26.0, *)
enum AutomationArtifactKind: String, Codable, Sendable, Hashable, CaseIterable {
    case transcriptImport = "transcript_import"
    case transcriptShotSpec = "transcript_shot_spec"
    case effectiveShotSpec = "effective_shot_spec"
    case referenceContract = "reference_contract"
    case shotFrameGenerationPlan = "shot_frame_generation_plan"
    case generatedFrameRecord = "generated_frame_record"
    case videoTaskRecord = "video_task_record"
    case qaResult = "qa_result"
}

@available(macOS 26.0, *)
enum AutomationBlockerCode: String, Codable, Sendable, Hashable, CaseIterable {
    case blockedMissingPlace = "blocked_missing_place"
    case blockedMissingCharacter = "blocked_missing_character"
    case blockedMissingReferenceRole = "blocked_missing_reference_role"
    case blockedMissingEditSource = "blocked_missing_edit_source"
    case blockedUnapprovedStartFrame = "blocked_unapproved_start_frame"
    case blockedUnapprovedEndFrame = "blocked_unapproved_end_frame"
    case blockedUploadFailed = "blocked_upload_failed"
    case blockedCostCap = "blocked_cost_cap"
    case failedProviderError = "failed_provider_error"
    case failedQA = "failed_qa"
    case needsManualReview = "needs_manual_review"
}

@available(macOS 26.0, *)
struct AutomationBlocker: Codable, Sendable, Hashable {
    var code: AutomationBlockerCode
    var message: String
    var field: String?
    var severity: String

    init(
        code: AutomationBlockerCode,
        message: String,
        field: String? = nil,
        severity: String = "blocking"
    ) {
        self.code = code
        self.message = message
        self.field = field
        self.severity = severity
    }
}

@available(macOS 26.0, *)
struct AutomationWorldContext: Codable, Sendable, Hashable {
    var sourcePath: String
    var timePeriod: String
    var environmental: String
    var aesthetic: String
    var ignoredDuplicatePaths: [String]

    var periodLine: String {
        timePeriod.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? timePeriod
    }
}

@available(macOS 26.0, *)
struct AutomationProjectSummary: Codable, Sendable, Hashable {
    var schemaVersion: Int
    var generatedAt: Date
    var projectRoot: String
    var scenesCount: Int
    var shotsCount: Int
    var placesCount: Int
    var songsCount: Int
    var characterRigCount: Int
    var scenesWithBackgroundID: Int
    var shotsWithPopulatedShotFrameGeneration: Int
    var shotsWithPopulatedShotBackgroundPlate: Int
    var worldContext: AutomationWorldContext?
    var warnings: [String]

    init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        projectRoot: String,
        scenesCount: Int,
        shotsCount: Int,
        placesCount: Int,
        songsCount: Int,
        characterRigCount: Int,
        scenesWithBackgroundID: Int,
        shotsWithPopulatedShotFrameGeneration: Int,
        shotsWithPopulatedShotBackgroundPlate: Int,
        worldContext: AutomationWorldContext?,
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.projectRoot = projectRoot
        self.scenesCount = scenesCount
        self.shotsCount = shotsCount
        self.placesCount = placesCount
        self.songsCount = songsCount
        self.characterRigCount = characterRigCount
        self.scenesWithBackgroundID = scenesWithBackgroundID
        self.shotsWithPopulatedShotFrameGeneration = shotsWithPopulatedShotFrameGeneration
        self.shotsWithPopulatedShotBackgroundPlate = shotsWithPopulatedShotBackgroundPlate
        self.worldContext = worldContext
        self.warnings = warnings
    }
}

@available(macOS 26.0, *)
struct TranscriptImport: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var sourceKind: String
    var sourcePath: String?
    var transcriptText: String
    var shotSpecs: [TranscriptShotSpec]
    var ambiguityReport: [AutomationBlocker]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceKind: String,
        sourcePath: String? = nil,
        transcriptText: String,
        shotSpecs: [TranscriptShotSpec] = [],
        ambiguityReport: [AutomationBlocker] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.transcriptText = transcriptText
        self.shotSpecs = shotSpecs
        self.ambiguityReport = ambiguityReport
    }
}

@available(macOS 26.0, *)
struct TranscriptShotSpec: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var transcriptImportID: UUID?
    var sceneID: UUID?
    var shotID: UUID?
    var rawText: String
    var placeID: UUID?
    var placeCandidate: String?
    var characterSlugs: [String]
    var newPlaceCandidate: String?
    var newCharacterCandidates: [String]
    var camera: String?
    var action: String
    var blockers: [AutomationBlocker]

    init(
        id: UUID = UUID(),
        transcriptImportID: UUID? = nil,
        sceneID: UUID? = nil,
        shotID: UUID? = nil,
        rawText: String,
        placeID: UUID? = nil,
        placeCandidate: String? = nil,
        characterSlugs: [String] = [],
        newPlaceCandidate: String? = nil,
        newCharacterCandidates: [String] = [],
        camera: String? = nil,
        action: String = "",
        blockers: [AutomationBlocker] = []
    ) {
        self.id = id
        self.transcriptImportID = transcriptImportID
        self.sceneID = sceneID
        self.shotID = shotID
        self.rawText = rawText
        self.placeID = placeID
        self.placeCandidate = placeCandidate
        self.characterSlugs = characterSlugs
        self.newPlaceCandidate = newPlaceCandidate
        self.newCharacterCandidates = newCharacterCandidates
        self.camera = camera
        self.action = action
        self.blockers = blockers
    }
}

@available(macOS 26.0, *)
struct EffectiveShotSpec: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var source: String
    var sceneID: UUID
    var sceneName: String
    var shotID: UUID
    var shotIndex: Int
    var shotName: String
    var startFrame: Int
    var endFrame: Int
    var backgroundID: UUID?
    var backgroundName: String?
    var approvedPlaceImagePath: String?
    var focusCharacterID: UUID?
    var focusCharacterSlug: String?
    var focusCharacterName: String?
    var characterIDs: [UUID]
    var characterSlugs: [String]
    var characterNames: [String]
    var cameraShot: String?
    var shotIntent: String?
    var action: String
    var notes: String
    var lyricExcerpt: String?
    var worldPeriod: String
    var regionalWorldCues: String
    var architectureMaterials: String
    var lighting: String
    var cameraFraming: String
    var visualTone: String
    var negativeGuardrails: [String]
    var prompt: String
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
enum ReferenceRole: String, Codable, Sendable, Hashable, CaseIterable {
    case locationIdentity = "location_identity"
    case spatialMap = "spatial_map"
    case landmarkDesign = "landmark_design"
    case characterIdentity = "character_identity"
    case characterCostume = "character_costume"
    case storyboardLayout = "storyboard_layout"
    case shotContinuity = "shot_continuity"
    case style
    case manualPinned = "manual_pinned"
}

@available(macOS 26.0, *)
enum ReferenceStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case candidate
    case pinned
    case rejected
}

@available(macOS 26.0, *)
struct ReferenceContractItem: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var role: ReferenceRole
    var status: ReferenceStatus
    var path: String
    var label: String
    var priority: Int
    var source: String
    var guidance: String?

    init(
        id: UUID = UUID(),
        role: ReferenceRole,
        status: ReferenceStatus = .candidate,
        path: String,
        label: String,
        priority: Int,
        source: String,
        guidance: String? = nil
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.path = path
        self.label = label
        self.priority = priority
        self.source = source
        self.guidance = guidance
    }
}

@available(macOS 26.0, *)
struct ReferenceContract: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var sceneID: UUID
    var shotID: UUID
    var shotIndex: Int
    var maxReferences: Int
    var roleQuotas: [ReferenceRole: Int]
    var references: [ReferenceContractItem]
    var blockers: [AutomationBlocker]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int,
        maxReferences: Int = 8,
        roleQuotas: [ReferenceRole: Int] = ReferenceContract.defaultRoleQuotas,
        references: [ReferenceContractItem] = [],
        blockers: [AutomationBlocker] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sceneID = sceneID
        self.shotID = shotID
        self.shotIndex = shotIndex
        self.maxReferences = maxReferences
        self.roleQuotas = roleQuotas
        self.references = references
        self.blockers = blockers
    }

    static let defaultRoleQuotas: [ReferenceRole: Int] = [
        .manualPinned: 3,
        .storyboardLayout: 1,
        .shotContinuity: 1,
        .locationIdentity: 2,
        .spatialMap: 1,
        .landmarkDesign: 2,
        .characterIdentity: 2,
        .characterCostume: 2,
        .style: 1
    ]

    var usableReferences: [ReferenceContractItem] {
        references.filter { $0.status != .rejected }
    }
}

@available(macOS 26.0, *)
struct GeneratedFrameRecord: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sceneID: UUID
    var shotID: UUID
    var shotIndex: Int
    var moment: String
    var provider: String
    var model: String
    var imageSize: String
    var aspectRatio: String
    var generationMode: String
    var status: String
    var estimatedCostUSD: Double
    var promptPath: String?
    var responsePath: String?
    var planPath: String?
    var referenceContractPath: String?
    var outputPath: String?
    var referencePaths: [String]
    var approvalStatus: String
    var approvalNotes: String?
    var approvalUpdatedAt: Date?
    var errorMessage: String?
    var blockers: [AutomationBlocker]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sceneID: UUID,
        shotID: UUID,
        shotIndex: Int = 0,
        moment: String,
        provider: String = "gemini",
        model: String = "",
        imageSize: String = "",
        aspectRatio: String = "",
        generationMode: String = "dry_run_placeholder",
        status: String = "not_started",
        estimatedCostUSD: Double = 0,
        promptPath: String? = nil,
        responsePath: String? = nil,
        planPath: String? = nil,
        referenceContractPath: String? = nil,
        outputPath: String? = nil,
        referencePaths: [String] = [],
        approvalStatus: String = "unapproved",
        approvalNotes: String? = nil,
        approvalUpdatedAt: Date? = nil,
        errorMessage: String? = nil,
        blockers: [AutomationBlocker] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sceneID = sceneID
        self.shotID = shotID
        self.shotIndex = shotIndex
        self.moment = moment
        self.provider = provider
        self.model = model
        self.imageSize = imageSize
        self.aspectRatio = aspectRatio
        self.generationMode = generationMode
        self.status = status
        self.estimatedCostUSD = estimatedCostUSD
        self.promptPath = promptPath
        self.responsePath = responsePath
        self.planPath = planPath
        self.referenceContractPath = referenceContractPath
        self.outputPath = outputPath
        self.referencePaths = referencePaths
        self.approvalStatus = approvalStatus
        self.approvalNotes = approvalNotes
        self.approvalUpdatedAt = approvalUpdatedAt
        self.errorMessage = errorMessage
        self.blockers = blockers
    }
}

@available(macOS 26.0, *)
struct VideoTaskRecord: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var sceneID: UUID
    var shotID: UUID
    var provider: String
    var model: String
    var prompt: String
    var durationSeconds: Double
    var status: String
    var startFrameURL: String?
    var endFrameURL: String?
    var providerTaskID: String?
    var outputPath: String?
    var attempt: Int
    var blockers: [AutomationBlocker]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sceneID: UUID,
        shotID: UUID,
        provider: String = "vidu",
        model: String = "",
        prompt: String = "",
        durationSeconds: Double = 0,
        status: String = "not_started",
        startFrameURL: String? = nil,
        endFrameURL: String? = nil,
        providerTaskID: String? = nil,
        outputPath: String? = nil,
        attempt: Int = 0,
        blockers: [AutomationBlocker] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sceneID = sceneID
        self.shotID = shotID
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.durationSeconds = durationSeconds
        self.status = status
        self.startFrameURL = startFrameURL
        self.endFrameURL = endFrameURL
        self.providerTaskID = providerTaskID
        self.outputPath = outputPath
        self.attempt = attempt
        self.blockers = blockers
    }
}

@available(macOS 26.0, *)
struct QAResult: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var targetKind: String
    var targetID: UUID
    var status: String
    var flags: [String]
    var blockers: [AutomationBlocker]
    var retryCount: Int
    var maxRetries: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        targetKind: String,
        targetID: UUID,
        status: String = "not_run",
        flags: [String] = [],
        blockers: [AutomationBlocker] = [],
        retryCount: Int = 0,
        maxRetries: Int = 2
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetKind = targetKind
        self.targetID = targetID
        self.status = status
        self.flags = flags
        self.blockers = blockers
        self.retryCount = retryCount
        self.maxRetries = maxRetries
    }
}
