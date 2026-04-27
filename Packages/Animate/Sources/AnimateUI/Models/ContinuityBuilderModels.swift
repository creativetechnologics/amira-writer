import Foundation

@available(macOS 26.0, *)
enum ContinuityBuilderCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case worldGeography = "world_geography"
    case placeTopography = "place_topography"
    case landmarkBridge = "landmark_bridge"
    case characterIdentity = "character_identity"
    case costumeContinuity = "costume_continuity"
    case vehicleProp = "vehicle_prop"
    case sceneContinuity = "scene_continuity"
    case styleContinuity = "style_continuity"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .worldGeography: return "World geography"
        case .placeTopography: return "Place/topography"
        case .landmarkBridge: return "Bridge/landmarks"
        case .characterIdentity: return "Character identity"
        case .costumeContinuity: return "Costume continuity"
        case .vehicleProp: return "Vehicles/props"
        case .sceneContinuity: return "Scene continuity"
        case .styleContinuity: return "Style continuity"
        }
    }

    var reviewSubjectLabel: String {
        switch self {
        case .worldGeography, .placeTopography, .landmarkBridge, .sceneContinuity:
            return "Place"
        case .characterIdentity, .costumeContinuity:
            return "Character"
        case .vehicleProp:
            return "Vehicle / prop"
        case .styleContinuity:
            return "Style"
        }
    }
}

@available(macOS 26.0, *)
enum ContinuityBuilderCandidateLabel: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case single
    case left
    case middle
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "Single"
        case .left: return "A"
        case .middle: return "Middle"
        case .right: return "B"
        }
    }
}

@available(macOS 26.0, *)
struct ContinuityBuilderCandidate: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var label: ContinuityBuilderCandidateLabel
    var title: String
    var imagePath: String?
    var source: String
    var referenceRole: String
    var promptRole: String
    var analysisSummary: String?

    init(
        id: UUID = UUID(),
        label: ContinuityBuilderCandidateLabel,
        title: String,
        imagePath: String?,
        source: String,
        referenceRole: String,
        promptRole: String,
        analysisSummary: String? = nil
    ) {
        self.id = id
        self.label = label
        self.title = title
        self.imagePath = imagePath
        self.source = source
        self.referenceRole = referenceRole
        self.promptRole = promptRole
        self.analysisSummary = analysisSummary
    }
}

@available(macOS 26.0, *)
struct ContinuityBuilderTurn: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var id: UUID
    var createdAt: Date
    var category: ContinuityBuilderCategory
    var title: String
    var question: String
    var priorityReason: String
    var promptSeed: String
    var negativeGuardrails: [String]
    var recommendedImageSize: String
    var recommendedAspectRatio: String
    var candidates: [ContinuityBuilderCandidate]
    var contextTags: [String]
    var requiresPaidGeneration: Bool
    var generationStatus: String

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        category: ContinuityBuilderCategory,
        title: String,
        question: String,
        priorityReason: String,
        promptSeed: String,
        negativeGuardrails: [String],
        recommendedImageSize: String = "1K",
        recommendedAspectRatio: String = "4:3",
        candidates: [ContinuityBuilderCandidate],
        contextTags: [String],
        requiresPaidGeneration: Bool = false,
        generationStatus: String = "dry_run_ready"
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.category = category
        self.title = title
        self.question = question
        self.priorityReason = priorityReason
        self.promptSeed = promptSeed
        self.negativeGuardrails = negativeGuardrails
        self.recommendedImageSize = recommendedImageSize
        self.recommendedAspectRatio = recommendedAspectRatio
        self.candidates = candidates
        self.contextTags = contextTags
        self.requiresPaidGeneration = requiresPaidGeneration
        self.generationStatus = generationStatus
    }
}

@available(macOS 26.0, *)
struct ContinuityBuilderFeedback: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var id: UUID
    var sessionID: UUID
    var turnID: UUID
    var submittedAt: Date
    var selectedCandidateLabel: ContinuityBuilderCandidateLabel?
    var closenessPercent: Int
    var notes: String
    var transcriptAudioPath: String?
    var interpretedFocus: [String]
    var shouldBecomePromptMemory: Bool

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        sessionID: UUID,
        turnID: UUID,
        submittedAt: Date = Date(),
        selectedCandidateLabel: ContinuityBuilderCandidateLabel?,
        closenessPercent: Int,
        notes: String,
        transcriptAudioPath: String? = nil,
        interpretedFocus: [String] = [],
        shouldBecomePromptMemory: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.submittedAt = submittedAt
        self.selectedCandidateLabel = selectedCandidateLabel
        self.closenessPercent = min(max(closenessPercent, 0), 100)
        self.notes = notes
        self.transcriptAudioPath = transcriptAudioPath
        self.interpretedFocus = interpretedFocus
        self.shouldBecomePromptMemory = shouldBecomePromptMemory
    }
}

@available(macOS 26.0, *)
struct ContinuityBuilderSession: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var projectRoot: String
    var activeTurnIndex: Int
    var turns: [ContinuityBuilderTurn]
    var feedback: [ContinuityBuilderFeedback]
    var nextPriorityQueue: [ContinuityBuilderCategory]
    var notes: String
    var startedAt: Date?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectRoot: String,
        activeTurnIndex: Int = 0,
        turns: [ContinuityBuilderTurn] = [],
        feedback: [ContinuityBuilderFeedback] = [],
        nextPriorityQueue: [ContinuityBuilderCategory] = ContinuityBuilderCategory.allCases,
        notes: String = "",
        startedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectRoot = projectRoot
        self.activeTurnIndex = activeTurnIndex
        self.turns = turns
        self.feedback = feedback
        self.nextPriorityQueue = nextPriorityQueue
        self.notes = notes
        self.startedAt = startedAt
    }

    var activeTurn: ContinuityBuilderTurn? {
        guard turns.indices.contains(activeTurnIndex) else { return nil }
        return turns[activeTurnIndex]
    }

    var hasStarted: Bool {
        startedAt != nil
    }
}
