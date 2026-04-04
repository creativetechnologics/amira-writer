import Foundation

@available(macOS 26.0, *)
struct ShotBackgroundPlate: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var sourceBackgroundID: UUID
    var cameraShot: String?
    var prompt: String = ""
    var generatedImagePath: String?
    var approvedImagePath: String?
    var variants: [String] = []
}

@available(macOS 26.0, *)
struct ShotFrameGeneration: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var firstFramePrompt: String = ""
    var firstFrameImagePath: String?
    var firstFrameVariants: [String] = []
    var firstFrameApproved: Bool = false
    var lastFramePrompt: String = ""
    var lastFrameImagePath: String?
    var lastFrameVariants: [String] = []
    var lastFrameApproved: Bool = false
    var motionDirection: String = ""
    var animationStyleNotes: String = ""
    var durationSeconds: Double = 4.0
    var aspectRatio: String = "16:9"
    var viduTaskID: String?
    var viduStatus: ViduTaskStatus = .idle
    var viduOutputPath: String?
}

enum ViduTaskStatus: String, Codable, Sendable, Hashable {
    case idle, queued, generating, succeeded, failed
}

@available(macOS 26.0, *)
struct AnimationStylePreset: Codable, Sendable, Hashable {
    var name: String = "Slightly Anime"
    var frameRateStyle: String = "variable"
    var holdFrames: Bool = true
    var impactFrames: Bool = true
    var motionBlurStyle: String = "speed lines"
    var aestheticNotes: String = ""
}

@available(macOS 26.0, *)
struct ViduBatchQueueItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var sceneName: String
    var shotIndex: Int
    var firstFramePath: String
    var lastFramePath: String
    var motionPrompt: String
    var durationSeconds: Double
    var aspectRatio: String
    var animationStyle: AnimationStylePreset
    var dateQueued: Date = Date()
}