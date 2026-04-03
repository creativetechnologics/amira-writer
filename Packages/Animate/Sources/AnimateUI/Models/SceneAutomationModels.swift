import Foundation

enum SceneExecutionMode: String, Codable, Sendable, CaseIterable, Hashable {
    case autoRecommend = "auto_recommend"
    case animateKitOnly = "animate_kit_only"
    case hybrid
    case generativeAssist = "generative_assist"

    var displayName: String {
        switch self {
        case .autoRecommend: "Auto Recommend"
        case .animateKitOnly: "Animate Kit Only"
        case .hybrid: "Hybrid"
        case .generativeAssist: "Generative Assist"
        }
    }

    var summary: String {
        switch self {
        case .autoRecommend:
            "Let the engine recommend the most economical route scene by scene."
        case .animateKitOnly:
            "Prefer in-house Animate kits, rigging, and reusable asset playback."
        case .hybrid:
            "Blend Animate coverage with generative video only where complexity spikes."
        case .generativeAssist:
            "Bias toward generative video assistance for complex shots or temporary coverage."
        }
    }
}

enum AutomationIntensity: String, Codable, Sendable, CaseIterable, Hashable {
    case subtle
    case balanced
    case expressive

    var displayName: String {
        switch self {
        case .subtle: "Subtle"
        case .balanced: "Balanced"
        case .expressive: "Expressive"
        }
    }
}

enum CameraAutomationStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case lockedCoverage = "locked_coverage"
    case motivated2D = "motivated_2d"
    case cinematicAssist = "cinematic_assist"

    var displayName: String {
        switch self {
        case .lockedCoverage: "Locked Coverage"
        case .motivated2D: "Motivated 2D"
        case .cinematicAssist: "Cinematic Assist"
        }
    }
}

enum LipSyncAssistMode: String, Codable, Sendable, CaseIterable, Hashable {
    case manualGuide = "manual_guide"
    case assistedGuide = "assisted_guide"
    case automaticMap = "automatic_map"

    var displayName: String {
        switch self {
        case .manualGuide: "Manual Guide"
        case .assistedGuide: "Assisted Guide"
        case .automaticMap: "Automatic Map"
        }
    }
}

enum CharacterAutomationStrategy: String, Codable, Sendable, CaseIterable, Hashable {
    case followSceneMode = "follow_scene_mode"
    case kitOnly = "kit_only"
    case hybridAssist = "hybrid_assist"
    case generativeFallback = "generative_fallback"

    var displayName: String {
        switch self {
        case .followSceneMode: "Follow Scene"
        case .kitOnly: "Kit Only"
        case .hybridAssist: "Hybrid Assist"
        case .generativeFallback: "Generative Fallback"
        }
    }
}

enum SceneAutomationPass: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case idleMotion = "idle_motion"
    case blinkPass = "blink_pass"
    case lookAt = "look_at"
    case lipSyncGuide = "lip_sync_guide"
    case cameraAssist = "camera_assist"
    case secondaryMotion = "secondary_motion"
    case backgroundParallax = "background_parallax"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idleMotion: "Idle Motion"
        case .blinkPass: "Blink Pass"
        case .lookAt: "Look-At"
        case .lipSyncGuide: "Lip Sync Guide"
        case .cameraAssist: "Camera Assist"
        case .secondaryMotion: "Secondary Motion"
        case .backgroundParallax: "Background Parallax"
        }
    }
}

struct SceneCharacterAutomationProfile: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var characterID: UUID?
    var characterSlug: String?
    var strategy: CharacterAutomationStrategy
    var preferredCostumeSetID: UUID?
    var preferredCostumeName: String?
    var useApprovedHeadTurnaround: Bool
    var useAccessoryOverlays: Bool
    var notes: String

    init(
        id: UUID = UUID(),
        characterID: UUID? = nil,
        characterSlug: String? = nil,
        strategy: CharacterAutomationStrategy = .followSceneMode,
        preferredCostumeSetID: UUID? = nil,
        preferredCostumeName: String? = nil,
        useApprovedHeadTurnaround: Bool = true,
        useAccessoryOverlays: Bool = true,
        notes: String = ""
    ) {
        self.id = id
        self.characterID = characterID
        self.characterSlug = characterSlug
        self.strategy = strategy
        self.preferredCostumeSetID = preferredCostumeSetID
        self.preferredCostumeName = preferredCostumeName
        self.useApprovedHeadTurnaround = useApprovedHeadTurnaround
        self.useAccessoryOverlays = useAccessoryOverlays
        self.notes = notes
    }
}

struct SceneAutomationProfile: Codable, Sendable, Hashable {
    var executionMode: SceneExecutionMode
    var actingIntensity: AutomationIntensity
    var cameraStyle: CameraAutomationStyle
    var lipSyncAssistMode: LipSyncAssistMode
    var enabledPasses: Set<SceneAutomationPass>
    var allowGenerativeVideoAssist: Bool
    var notes: String
    var characterProfiles: [SceneCharacterAutomationProfile]

    init(
        executionMode: SceneExecutionMode = .autoRecommend,
        actingIntensity: AutomationIntensity = .balanced,
        cameraStyle: CameraAutomationStyle = .motivated2D,
        lipSyncAssistMode: LipSyncAssistMode = .assistedGuide,
        enabledPasses: Set<SceneAutomationPass> = [
            .idleMotion, .blinkPass, .lookAt, .lipSyncGuide, .cameraAssist
        ],
        allowGenerativeVideoAssist: Bool = true,
        notes: String = "",
        characterProfiles: [SceneCharacterAutomationProfile] = []
    ) {
        self.executionMode = executionMode
        self.actingIntensity = actingIntensity
        self.cameraStyle = cameraStyle
        self.lipSyncAssistMode = lipSyncAssistMode
        self.enabledPasses = enabledPasses
        self.allowGenerativeVideoAssist = allowGenerativeVideoAssist
        self.notes = notes
        self.characterProfiles = characterProfiles
    }

    static func defaultProfile(
        for scene: AnimationScene,
        characters: [AnimationCharacter]
    ) -> SceneAutomationProfile {
        var profile = SceneAutomationProfile()
        profile.sync(with: scene, characters: characters)
        return profile
    }

    mutating func sync(
        with scene: AnimationScene,
        characters: [AnimationCharacter]
    ) {
        let sceneCharacters = scene.characterIDs.compactMap { id in
            characters.first(where: { $0.id == id })
        }

        let existingBySlug = Dictionary(
            uniqueKeysWithValues: characterProfiles.compactMap { profile in
                profile.characterSlug.map { ($0, profile) }
            }
        )

        let existingByID = Dictionary(
            uniqueKeysWithValues: characterProfiles.compactMap { profile in
                profile.characterID.map { ($0, profile) }
            }
        )

        characterProfiles = sceneCharacters.map { character in
            var resolved = existingByID[character.id]
                ?? existingBySlug[character.owpSlug]
                ?? SceneCharacterAutomationProfile(
                    characterID: character.id,
                    characterSlug: character.owpSlug,
                    preferredCostumeSetID: character.costumeReferenceSets.first?.id,
                    preferredCostumeName: character.costumeReferenceSets.first?.name
                )

            resolved.characterID = character.id
            resolved.characterSlug = character.owpSlug

            if let preferredCostumeSetID = resolved.preferredCostumeSetID,
               let costume = character.costumeReferenceSets.first(where: { $0.id == preferredCostumeSetID }) {
                resolved.preferredCostumeName = costume.name
            } else if let preferredCostumeName = resolved.preferredCostumeName,
                      let costume = character.costumeReferenceSets.first(where: {
                          $0.name.caseInsensitiveCompare(preferredCostumeName) == .orderedSame
                      }) {
                resolved.preferredCostumeSetID = costume.id
                resolved.preferredCostumeName = costume.name
            } else {
                resolved.preferredCostumeSetID = character.costumeReferenceSets.first?.id
                resolved.preferredCostumeName = character.costumeReferenceSets.first?.name
            }

            return resolved
        }
    }

    func characterProfile(for characterID: UUID) -> SceneCharacterAutomationProfile? {
        characterProfiles.first(where: { $0.characterID == characterID || $0.id == characterID })
    }
}

enum SceneAutomationReadiness: String, Sendable, Hashable {
    case missing
    case partial
    case ready

    var displayName: String {
        switch self {
        case .missing: "Missing"
        case .partial: "Partial"
        case .ready: "Ready"
        }
    }
}

struct SceneAutomationChecklistItem: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var detail: String
    var metric: String
    var readiness: SceneAutomationReadiness
}

struct SceneAutomationCostumeSummary: Identifiable, Sendable, Hashable {
    var id: UUID
    var costumeName: String
    var approvedFullBodyPoseCount: Int
    var approvedAccessoryCount: Int
    var readiness: SceneAutomationReadiness
}

struct SceneAutomationCharacterSummary: Identifiable, Sendable, Hashable {
    var id: UUID
    var characterName: String
    var readiness: SceneAutomationReadiness
    var approvedMasterSheetCount: Int
    var approvedHeadPoseCount: Int
    var activePackageName: String?
    var activePackageValid: Bool
    var activePackageExpressionCount: Int
    var activePackageVisemeCount: Int
    var costumeSummaries: [SceneAutomationCostumeSummary]

    var summaryLine: String {
        let packageLabel = activePackageName ?? "No package"
        return "\(approvedHeadPoseCount)/6 head • \(packageLabel) • \(activePackageVisemeCount) visemes"
    }
}

struct SceneAutomationPlan: Sendable, Hashable {
    var sceneID: UUID
    var configuredExecutionMode: SceneExecutionMode
    var recommendedExecutionMode: SceneExecutionMode
    var effectiveExecutionMode: SceneExecutionMode
    var readinessScore: Double
    var complexityScore: Double
    var supportedPasses: [SceneAutomationPass]
    var checklist: [SceneAutomationChecklistItem]
    var characterSummaries: [SceneAutomationCharacterSummary]
    var recommendedNextSteps: [String]
    var summary: String
}
