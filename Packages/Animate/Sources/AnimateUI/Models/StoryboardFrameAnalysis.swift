import Foundation
import ProjectKit

// MARK: - StoryboardFrameAnalysis

/// Sidecar metadata for a single storyboard PNG frame.
///
/// The model is intentionally lightweight so we can serialize analysis results
/// without pulling in the storyboard analysis pipeline itself.
@available(macOS 26.0, *)
struct StoryboardFrameAnalysis: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var sceneID: UUID
    var shotID: UUID
    var frame: StoryboardFrame
    var imagePath: String
    var projectRelativePath: String?
    var contentHash: String?
    var status: StoryboardFrameAnalysisStatus
    var summary: String?
    var detectedEntities: [StoryboardDetectedEntity]
    var compositionGrid: StoryboardCompositionGrid?
    var cameraRead: StoryboardCameraRead?
    var motionVectors: [StoryboardMotionVector]
    var visibleTextLabels: [StoryboardTextLabel]
    var conflicts: [StoryboardAnalysisConflict]
    var timestamps: StoryboardFrameAnalysisTimestamps
    var analysisPrompt: String?
    var analysisBackend: String?
    var analysisModel: String?

    init(
        schemaVersion: Int = 1,
        sceneID: UUID,
        shotID: UUID,
        frame: StoryboardFrame,
        imagePath: String,
        projectRelativePath: String? = nil,
        contentHash: String? = nil,
        status: StoryboardFrameAnalysisStatus = .pending,
        summary: String? = nil,
        detectedEntities: [StoryboardDetectedEntity] = [],
        compositionGrid: StoryboardCompositionGrid? = nil,
        cameraRead: StoryboardCameraRead? = nil,
        motionVectors: [StoryboardMotionVector] = [],
        visibleTextLabels: [StoryboardTextLabel] = [],
        conflicts: [StoryboardAnalysisConflict] = [],
        timestamps: StoryboardFrameAnalysisTimestamps = StoryboardFrameAnalysisTimestamps(),
        analysisPrompt: String? = nil,
        analysisBackend: String? = nil,
        analysisModel: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sceneID = sceneID
        self.shotID = shotID
        self.frame = frame
        self.imagePath = imagePath
        self.projectRelativePath = projectRelativePath
        self.contentHash = contentHash
        self.status = status
        self.summary = summary
        self.detectedEntities = detectedEntities
        self.compositionGrid = compositionGrid
        self.cameraRead = cameraRead
        self.motionVectors = motionVectors
        self.visibleTextLabels = visibleTextLabels
        self.conflicts = conflicts
        self.timestamps = timestamps
        self.analysisPrompt = analysisPrompt
        self.analysisBackend = analysisBackend
        self.analysisModel = analysisModel
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sceneID
        case shotID
        case frame
        case imagePath
        case projectRelativePath
        case contentHash
        case status
        case summary
        case detectedEntities
        case compositionGrid
        case cameraRead
        case motionVectors
        case visibleTextLabels
        case conflicts
        case timestamps
        case analysisPrompt
        case analysisBackend
        case analysisModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sceneID = try container.decode(UUID.self, forKey: .sceneID)
        shotID = try container.decode(UUID.self, forKey: .shotID)
        let frameRawValue = try container.decode(String.self, forKey: .frame)
        guard let decodedFrame = StoryboardFrame(rawValue: frameRawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .frame,
                in: container,
                debugDescription: "Unknown storyboard frame '\(frameRawValue)'."
            )
        }
        frame = decodedFrame
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        projectRelativePath = try container.decodeIfPresent(String.self, forKey: .projectRelativePath)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        status = try container.decodeIfPresent(StoryboardFrameAnalysisStatus.self, forKey: .status) ?? .pending
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        detectedEntities = try container.decodeIfPresent([StoryboardDetectedEntity].self, forKey: .detectedEntities) ?? []
        compositionGrid = try container.decodeIfPresent(StoryboardCompositionGrid.self, forKey: .compositionGrid)
        cameraRead = try container.decodeIfPresent(StoryboardCameraRead.self, forKey: .cameraRead)
        motionVectors = try container.decodeIfPresent([StoryboardMotionVector].self, forKey: .motionVectors) ?? []
        visibleTextLabels = try container.decodeIfPresent([StoryboardTextLabel].self, forKey: .visibleTextLabels) ?? []
        conflicts = try container.decodeIfPresent([StoryboardAnalysisConflict].self, forKey: .conflicts) ?? []
        timestamps = try container.decodeIfPresent(StoryboardFrameAnalysisTimestamps.self, forKey: .timestamps) ?? StoryboardFrameAnalysisTimestamps()
        analysisPrompt = try container.decodeIfPresent(String.self, forKey: .analysisPrompt)
        analysisBackend = try container.decodeIfPresent(String.self, forKey: .analysisBackend)
        analysisModel = try container.decodeIfPresent(String.self, forKey: .analysisModel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sceneID, forKey: .sceneID)
        try container.encode(shotID, forKey: .shotID)
        try container.encode(frame.rawValue, forKey: .frame)
        try container.encode(imagePath, forKey: .imagePath)
        try container.encodeIfPresent(projectRelativePath, forKey: .projectRelativePath)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(detectedEntities, forKey: .detectedEntities)
        try container.encodeIfPresent(compositionGrid, forKey: .compositionGrid)
        try container.encodeIfPresent(cameraRead, forKey: .cameraRead)
        try container.encode(motionVectors, forKey: .motionVectors)
        try container.encode(visibleTextLabels, forKey: .visibleTextLabels)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(timestamps, forKey: .timestamps)
        try container.encodeIfPresent(analysisPrompt, forKey: .analysisPrompt)
        try container.encodeIfPresent(analysisBackend, forKey: .analysisBackend)
        try container.encodeIfPresent(analysisModel, forKey: .analysisModel)
    }
}

// MARK: - StoryboardFrameAnalysisStatus

@available(macOS 26.0, *)
enum StoryboardFrameAnalysisStatus: String, Codable, Equatable, Sendable {
    case pending
    case analyzing
    case complete
    case needsReview
    case conflicted
    case failed

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? ""
        self = StoryboardFrameAnalysisStatus(rawValue: rawValue) ?? .pending
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - StoryboardDetectedEntity

@available(macOS 26.0, *)
struct StoryboardDetectedEntity: Codable, Equatable, Sendable {
    var identifier: String?
    var targetID: UUID?
    var kind: String?
    var label: String?
    var boundingBox: StoryboardNormalizedRect?
    var gridCell: String?
    var confidence: Double?
    var source: String?
    var notes: String?
}

// MARK: - StoryboardNormalizedRect

@available(macOS 26.0, *)
struct StoryboardNormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - StoryboardCompositionGrid

@available(macOS 26.0, *)
struct StoryboardCompositionGrid: Codable, Equatable, Sendable {
    var rows: Int?
    var columns: Int?
    var focus: String?
    var highlightedCells: [String]?
    var notes: String?
}

// MARK: - StoryboardCameraRead

@available(macOS 26.0, *)
struct StoryboardCameraRead: Codable, Equatable, Sendable {
    var shotSize: String?
    var angle: String?
    var movement: String?
    var lens: String?
    var notes: String?
}

// MARK: - StoryboardMotionVector

@available(macOS 26.0, *)
struct StoryboardMotionVector: Codable, Equatable, Sendable {
    var label: String?
    var from: StoryboardPoint?
    var to: StoryboardPoint?
    var confidence: Double?
    var notes: String?
}

// MARK: - StoryboardTextLabel

@available(macOS 26.0, *)
struct StoryboardTextLabel: Codable, Equatable, Sendable {
    var text: String
    var boundingBox: StoryboardNormalizedRect?
    var confidence: Double?
    var notes: String?
}

// MARK: - StoryboardPoint

@available(macOS 26.0, *)
struct StoryboardPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - StoryboardAnalysisConflict

@available(macOS 26.0, *)
struct StoryboardAnalysisConflict: Codable, Equatable, Sendable {
    var field: String?
    var expected: String?
    var observed: String?
    var severity: String?
    var notes: String?
}

// MARK: - StoryboardFrameAnalysisTimestamps

@available(macOS 26.0, *)
struct StoryboardFrameAnalysisTimestamps: Codable, Equatable, Sendable {
    var createdAt: Date?
    var updatedAt: Date?
    var analyzedAt: Date?
    var reviewedAt: Date?

    init(
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        analyzedAt: Date? = nil,
        reviewedAt: Date? = nil
    ) {
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.analyzedAt = analyzedAt
        self.reviewedAt = reviewedAt
    }
}
