import Foundation
import Observation

@available(macOS 26.0, *)
enum AnimateWorkspaceDockTab: String, CaseIterable, Identifiable {
    case plan
    case review
    case resolve
    case assets
    case shots
    case execute
    case sync
    case lighting
    case graph
    case handoff
    case motion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan JSON"
        case .review: "Review"
        case .resolve: "Resolve"
        case .assets: "Assets"
        case .shots: "Shots"
        case .execute: "Execute"
        case .sync: "Script Sync"
        case .lighting: "Lighting"
        case .graph: "Scene Graph"
        case .handoff: "LLM Handoff"
        case .motion: "Motion"
        }
    }
}

@available(macOS 26.0, *)
@Observable @MainActor
final class AnimateWorkspaceState {
    var selectedDockTab: AnimateWorkspaceDockTab = .plan
    var planJSONText: String = ""
    var lastAppliedReport: LLMAnimationValidationReport?
    var lastExecutionPreview: AnimateExecutionPreview?
    var selectedPresetPreviewID: UUID?
    var lastPresetPreview: AnimatePresetPreview?
    var lastDialogueVisemePreview: AnimateDialogueVisemePreview?
    var lastDialogueVisemePreviewPlanText: String = ""
    var lastShotSeedReport: AnimateShotSeedReport?
    var lastAssetRequirementsDatabase: AnimateAssetRequirementDatabase?
    var isRefreshingAssetRequirements = false
    var isPreviewingDialogueVisemes = false
    var isApplyingDialoguePlan = false
    var seededSceneID: UUID?
    var reviewFocusedSceneID: UUID?
    var reviewFocusedShotID: UUID?
    var librettoPromptOverridesBySceneID: [String: AnimateLibrettoPromptOverrides] = [:]
}

@available(macOS 26.0, *)
struct AnimateLibrettoPromptOverrides: Codable, Sendable, Hashable {
    var approvedRecurringObjects: String = ""
    var timingNotes: String = ""
    var directingGuidance: String = ""
    var operatorNotes: String = ""
}

@available(macOS 26.0, *)
struct AnimatePlanRoleDelta: Identifiable, Codable, Sendable {
    var id: String { role }
    var role: String
    var currentCount: Int
    var proposedCount: Int
}

@available(macOS 26.0, *)
struct AnimateShotSeedReport: Codable, Sendable {
    struct SeededShot: Identifiable, Codable, Sendable {
        var id: String
        var title: String
        var startFrame: Int
        var endFrame: Int
        var source: String
        var detail: String
    }

    var sceneID: String
    var sceneName: String
    var scriptDirectionCount: Int
    var cameraDirectionCount: Int
    var objectDirectionCount: Int
    var lyricLineCount: Int
    var seededShots: [SeededShot]
    var warnings: [String]
}

@available(macOS 26.0, *)
struct AnimatePlanReview: Codable, Sendable {
    var currentTrackCount: Int
    var proposedTrackCount: Int
    var currentFrames: Int
    var proposedFrames: Int
    var newTracks: [String]
    var overlappingTracks: [String]
    var currentOnlyTracks: [String]
    var roleDeltas: [AnimatePlanRoleDelta]
    var characterSetups: [CharacterSetup]
    var warnings: [String]
}

@available(macOS 26.0, *)
struct AnimateShotPlanSlicePreview: Codable, Sendable {
    struct CommandCounts: Codable, Sendable {
        var placements: Int
        var objectPlacements: Int
        var motions: Int
        var objectMotions: Int
        var expressions: Int
        var dialogueBeats: Int
        var shadowCues: Int
        var objectStateCues: Int
        var cameraMoves: Int
        var presetApplications: Int

        var total: Int {
            placements + objectPlacements + motions + objectMotions + expressions + dialogueBeats + shadowCues + objectStateCues + cameraMoves + presetApplications
        }
    }

    var sceneID: String
    var sceneName: String
    var shotID: String
    var shotTitle: String
    var frameRangeLabel: String
    var commandCounts: CommandCounts
    var unanchoredCommandCount: Int
    var warnings: [String]
    var plan: LLMAnimationPlan
    var review: AnimatePlanReview
    var applyPreview: AnimatePlanApplyPreview
}

@available(macOS 26.0, *)
struct AnimateDialogueVisemePreview: Codable, Sendable {
    struct Effect: Identifiable, Codable, Sendable {
        var id = UUID()
        var characterName: String
        var trackName: String
        var audioPath: String
        var transcriptExcerpt: String?
        var startFrame: Int
        var endFrame: Int
        var visemeCount: Int
        var currentValue: String?
        var proposedValue: String?
        var changeKind: AnimateExecutionPreview.Effect.ChangeKind
        var detail: String
        var shotContexts: [AnimatePlanApplyPreview.Effect.ShotContext] = []

        var changeKindLabel: String {
            switch changeKind {
            case .create: "CREATE"
            case .update: "UPDATE"
            case .clear: "CLEAR"
            case .activate: "ACTIVATE"
            case .switchSelection: "SWITCH"
            case .noChange: "NO CHANGE"
            }
        }

        var frameRangeLabel: String {
            if startFrame == endFrame {
                return "Frame \(startFrame)"
            }
            return "\(startFrame)–\(endFrame)"
        }
    }

    var sceneID: String
    var sceneName: String
    var beatCount: Int
    var effectCount: Int
    var actionableEffectCount: Int
    var warnings: [String]
    var effects: [Effect]
}

@available(macOS 26.0, *)
struct AnimateLightingPacket: Codable, Sendable {
    struct SharedLightWorld: Codable, Sendable {
        var name: String
        var description: String
        var temperature: String
        var contrast: String
    }

    struct Channel: Codable, Sendable {
        var name: String
        var purpose: String
    }

    struct CharacterPriority: Codable, Sendable {
        var characterID: String
        var name: String
        var protectChannel: String
        var priorityNotes: [String]
    }

    var sceneID: String
    var sceneName: String
    var locationID: String?
    var locationName: String
    var approvedBackgroundImagePath: String?
    var effectiveShot: String?
    var shotIntent: String?
    var beatLabel: String?
    var executionBias: String
    var lightingState: String
    var sharedLightWorld: SharedLightWorld
    var zones: [String]
    var practicals: [String]
    var channels: [Channel]
    var characterPriorities: [CharacterPriority]
    var focusCharacterName: String?
}

@available(macOS 26.0, *)
struct AnimateSceneExecutionPacket: Codable, Sendable {
    struct PlaceResolution: Codable, Sendable {
        var placeID: String?
        var name: String
        var approvedImagePath: String?
        var imageVariantCount: Int
        var summary: String
    }

    struct SubsystemMetric: Codable, Sendable {
        var title: String
        var score: Double
        var readiness: String
        var detail: String
    }

    struct CharacterResolution: Codable, Sendable {
        var characterID: String
        var characterSlug: String
        var packageSelectionSlug: String
        var name: String
        var packageID: String?
        var packageName: String?
        var packageKind: String?
        var packageValid: Bool
        var assetCount: Int
        var referenceAssetCount: Int
        var basePoseCount: Int
        var headPoseCount: Int
        var visemeCount: Int
        var expressionCount: Int
        var preferredCostumeName: String?
        var primaryAssetPath: String?
        var validationErrors: [String]
        var priorityWork: [String]
    }

    struct ObjectResolution: Codable, Sendable {
        var objectID: String
        var objectName: String
        var currentState: String
        var approvedImagePath: String?
        var variantCount: Int
        var hasResolvedArt: Bool
        var visible: Bool
        var opacity: Double
        var positionX: Double
        var positionY: Double
        var zOrder: Int
        var attachmentTarget: String?
        var attachmentKind: String?
        var attachmentSubject: String?
        var attachmentAnchor: String?
        var notes: String
    }

    struct UnresolvedNeed: Identifiable, Codable, Sendable {
        var id = UUID()
        var scope: String
        var title: String
        var detail: String
        var severity: String
    }

    var sceneID: String
    var sceneName: String
    var executionMode: String
    var readinessScore: Double
    var complexityScore: Double
    var trackCount: Int
    var place: PlaceResolution
    var subsystemMetrics: [SubsystemMetric]
    var characterResolutions: [CharacterResolution]
    var objectResolutions: [ObjectResolution]
    var unresolvedNeeds: [UnresolvedNeed]
}

@available(macOS 26.0, *)
struct AnimateAssetRequirementDatabase: Codable, Sendable {
    struct Summary: Codable, Sendable {
        var sceneCount: Int
        var entryCount: Int
        var readyCount: Int
        var needsArtCount: Int
        var needsDefinitionCount: Int
    }

    struct SceneSummary: Identifiable, Codable, Sendable {
        var id: String { sceneID }
        var sceneID: String
        var sceneName: String
        var placeName: String
        var shotCount: Int
        var objectMentionCount: Int
        var unresolvedCount: Int
    }

    struct PlacementHint: Identifiable, Codable, Sendable {
        var id = UUID()
        var shotTitle: String?
        var x: Double?
        var y: Double?
        var zOrder: Int?
        var attachmentTarget: String?
        var detail: String
    }

    struct Occurrence: Identifiable, Codable, Sendable {
        var id = UUID()
        var sceneID: String
        var sceneName: String
        var shotTitles: [String]
        var sourceLineNumbers: [Int]
    }

    struct Entry: Identifiable, Codable, Sendable {
        enum Status: String, Codable, Sendable {
            case ready
            case needsArt = "needs_art"
            case needsDefinition = "needs_definition"
        }

        var id = UUID()
        var key: String
        var kind: String
        var name: String
        var status: Status
        var summary: String
        var approvedImagePath: String?
        var variantCount: Int
        var hasResolvedArt: Bool
        var requiredStates: [String]
        var requiredAttachments: [String]
        var requiredCameraShots: [String]
        var requiredShotIntents: [String]
        var placementHints: [PlacementHint]
        var occurrences: [Occurrence]
    }

    var generatedAt: Date
    var summary: Summary
    var scenes: [SceneSummary]
    var entries: [Entry]
}

@available(macOS 26.0, *)
struct AnimateSceneOrchestrationPacket: Codable, Sendable {
    var sync: AnimateSceneSyncPacket
    var execution: AnimateSceneExecutionPacket
    var lighting: AnimateLightingPacket
    var review: AnimatePlanReview
}

@available(macOS 26.0, *)
struct AnimateExecutionBundle: Codable, Sendable {
    struct Action: Identifiable, Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case activatePackage
            case cameraDefaultShot
            case cameraShot
            case cameraFocus
            case cameraIntent
            case cameraBeatLabel
        }

        var id = UUID()
        var kind: Kind
        var title: String
        var detail: String
        var packageSelectionSlug: String?
        var packageID: String?
        var cameraShot: String?
        var focusCharacterID: String?
        var shotIntent: String?
        var beatLabel: String?

        var kindLabel: String {
            switch kind {
            case .activatePackage: "PACKAGE"
            case .cameraDefaultShot: "DEFAULT"
            case .cameraShot: "SHOT"
            case .cameraFocus: "FOCUS"
            case .cameraIntent: "INTENT"
            case .cameraBeatLabel: "BEAT"
            }
        }
    }

    struct RecommendedPreset: Identifiable, Codable, Sendable {
        var id: UUID
        var name: String
        var summary: String
        var cameraShot: String?
        var shotIntent: String?
    }

    var sceneID: String
    var sceneName: String
    var executionMode: String
    var inferredIntent: String?
    var effectiveShot: String?
    var focusCharacterName: String?
    var actions: [Action]
    var recommendedPresets: [RecommendedPreset]
    var blockers: [String]
}

@available(macOS 26.0, *)
struct AnimateExecutionPreview: Codable, Sendable {
    struct Effect: Identifiable, Codable, Sendable {
        enum Scope: String, Codable, Sendable {
            case packageSelection
            case timelineCue
        }

        enum ChangeKind: String, Codable, Sendable {
            case create
            case update
            case clear
            case activate
            case switchSelection
            case noChange
        }

        var id = UUID()
        var actionKind: String
        var title: String
        var scope: Scope
        var target: String
        var trackName: String?
        var frame: Int?
        var currentValue: String?
        var currentSource: String
        var proposedValue: String?
        var changeKind: ChangeKind
        var detail: String

        var changeKindLabel: String {
            switch changeKind {
            case .create: "CREATE"
            case .update: "UPDATE"
            case .clear: "CLEAR"
            case .activate: "ACTIVATE"
            case .switchSelection: "SWITCH"
            case .noChange: "NO CHANGE"
            }
        }
    }

    var sceneID: String
    var sceneName: String
    var effectCount: Int
    var actionableEffectCount: Int
    var packageEffectCount: Int
    var timelineEffectCount: Int
    var noChangeEffectCount: Int
    var effects: [Effect]
    var warnings: [String]
}

@available(macOS 26.0, *)
struct AnimatePresetPreview: Codable, Sendable {
    var presetID: UUID
    var presetName: String
    var frame: Int
    var effectCount: Int
    var actionableEffectCount: Int
    var clearEffectCount: Int
    var effects: [AnimateExecutionPreview.Effect]
    var warnings: [String]
}

@available(macOS 26.0, *)
struct AnimatePlanApplyPreview: Codable, Sendable {
    struct Effect: Identifiable, Codable, Sendable {
        struct ShotContext: Identifiable, Codable, Sendable, Hashable {
            var id: String
            var title: String
            var frameRangeLabel: String
        }

        enum Scope: String, Codable, Sendable {
            case sceneMetadata
            case sceneMembership
            case timelineTrack
            case cameraTrack
            case audioPath
        }

        var id = UUID()
        var scope: Scope
        var title: String
        var target: String
        var currentValue: String?
        var proposedValue: String?
        var changeKind: AnimateExecutionPreview.Effect.ChangeKind
        var detail: String
        var startFrame: Int? = nil
        var endFrame: Int? = nil
        var shotContexts: [ShotContext] = []

        var changeKindLabel: String {
            switch changeKind {
            case .create: "CREATE"
            case .update: "UPDATE"
            case .clear: "CLEAR"
            case .activate: "ACTIVATE"
            case .switchSelection: "SWITCH"
            case .noChange: "NO CHANGE"
            }
        }

        var frameRangeLabel: String? {
            switch (startFrame, endFrame) {
            case let (start?, end?) where start == end:
                return "Frame \(start)"
            case let (start?, end?):
                return "\(start)–\(end)"
            case let (start?, nil):
                return "Frame \(start)"
            case let (nil, end?):
                return "Frame \(end)"
            default:
                return nil
            }
        }
    }

    var sceneID: String
    var sceneName: String
    var currentTrackCount: Int
    var proposedTrackCount: Int
    var currentFrames: Int
    var proposedFrames: Int
    var effectCount: Int
    var actionableEffectCount: Int
    var effects: [Effect]
    var warnings: [String]
}

@available(macOS 26.0, *)
struct AnimateSceneSyncPacket: Codable, Sendable {
    struct CharacterNode: Codable, Sendable {
        var id: String
        var name: String
        var packageName: String?
        var packageReady: Bool
        var headPoseCount: Int
        var visemeCount: Int
        var expressionCount: Int
        var preferredCostume: String?
    }

    struct DirectionTemplateNode: Codable, Sendable {
        var defaultCameraShot: String?
        var focusCharacterSlug: String?
        var notes: String
    }

    struct ObjectNode: Codable, Sendable {
        var id: String
        var name: String
        var currentState: String
        var approvedImagePath: String?
        var variantCount: Int
        var hasResolvedArt: Bool
        var visible: Bool
        var opacity: Double
        var positionX: Double
        var positionY: Double
        var zOrder: Int
        var attachmentTarget: String?
        var attachmentKind: String?
        var attachmentSubject: String?
        var attachmentAnchor: String?
    }

    struct AutomationNode: Codable, Sendable {
        var recommendedExecutionMode: String
        var effectiveExecutionMode: String
        var readinessScore: Double
        var complexityScore: Double
        var summary: String
        var nextSteps: [String]
    }

    struct CameraNode: Codable, Sendable {
        var currentShot: String?
        var defaultShot: String?
        var effectiveShot: String?
        var focusCharacterID: String?
        var shotIntent: String?
        var beatLabel: String?
        var beatNotes: String?
    }

    struct TrackRoleCount: Codable, Sendable {
        var role: String
        var count: Int
    }

    struct LegacyDirection: Codable, Sendable {
        var tag: String
        var primaryValue: String
        var lineNumber: Int
        var parameters: [String: String]
    }

    struct ShotNode: Codable, Sendable {
        var id: String
        var title: String
        var detail: String
        var startFrame: Int
        var endFrame: Int
        var startSeconds: Double
        var endSeconds: Double
        var startTimecode: String
        var endTimecode: String
        var durationFrames: Int
        var durationTimecode: String
        var provenance: String
    }

    var sceneID: String
    var sceneName: String
    var owsSongPath: String
    var defaultAudioPath: String?
    var backgroundName: String?
    var backgroundApprovedImagePath: String?
    var cast: [CharacterNode]
    var objects: [ObjectNode]
    var directionTemplate: DirectionTemplateNode?
    var automation: AutomationNode?
    var camera: CameraNode
    var shots: [ShotNode]
    var trackRoles: [TrackRoleCount]
    var availableShotPresets: [String]
    var legacyDirections: [LegacyDirection]
    var lyrics: String
    var parseErrorCount: Int
}
