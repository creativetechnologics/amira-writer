import Foundation

struct CharacterPackageManifest: Identifiable, Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var id: UUID
    var slug: String
    var displayName: String
    var characterDescription: String
    var packageKind: CharacterPackageKind
    var tags: [String]
    var defaults: CharacterPackageDefaults
    var assets: [CharacterPackageAsset]
    var blueprints: [CharacterGenerationBlueprint]

    init(
        schemaVersion: Int = CharacterPackageManifest.currentSchemaVersion,
        id: UUID = UUID(),
        slug: String,
        displayName: String,
        characterDescription: String = "",
        packageKind: CharacterPackageKind = .hero,
        tags: [String] = [],
        defaults: CharacterPackageDefaults = .init(),
        assets: [CharacterPackageAsset] = [],
        blueprints: [CharacterGenerationBlueprint] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.slug = slug
        self.displayName = displayName
        self.characterDescription = characterDescription
        self.packageKind = packageKind
        self.tags = tags
        self.defaults = defaults
        self.assets = assets
        self.blueprints = blueprints
    }

    var normalizedSlug: String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var normalized = String(normalizedScalars)

        while normalized.contains("--") {
            normalized = normalized.replacingOccurrences(of: "--", with: "-")
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

enum CharacterPackageKind: String, Codable, Sendable, CaseIterable {
    case hero
    case supporting
    case background
}

struct CharacterPackageDefaults: Codable, Sendable, Hashable {
    var preferredAngle: AngleView?
    var preferredPose: CharacterPackagePose?
    var defaultCanvasSize: CharacterPackageCanvasSize?

    init(
        preferredAngle: AngleView? = nil,
        preferredPose: CharacterPackagePose? = nil,
        defaultCanvasSize: CharacterPackageCanvasSize? = nil
    ) {
        self.preferredAngle = preferredAngle
        self.preferredPose = preferredPose
        self.defaultCanvasSize = defaultCanvasSize
    }
}

struct CharacterPackageCanvasSize: Codable, Sendable, Hashable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

enum CharacterPackagePlacementMode: String, Codable, Sendable, Hashable, CaseIterable {
    case framed
    case fullCanvasAligned
}

struct CharacterPackageAssetPlacement: Codable, Sendable, Hashable {
    var mode: CharacterPackagePlacementMode?
    var normalizedCenter: CharacterPackageNormalizedPoint?
    var normalizedSize: CharacterPackageNormalizedSize?
    var normalizedPivot: CharacterPackageNormalizedPoint?
    var zOrderOverride: Int?
    var usesFullCanvasPlacement: Bool

    enum CodingKeys: String, CodingKey {
        case mode
        case normalizedCenter
        case normalizedSize
        case normalizedPivot
        case zOrderOverride
        case usesFullCanvasPlacement
    }

    init(
        mode: CharacterPackagePlacementMode? = nil,
        normalizedCenter: CharacterPackageNormalizedPoint? = nil,
        normalizedSize: CharacterPackageNormalizedSize? = nil,
        normalizedPivot: CharacterPackageNormalizedPoint? = nil,
        zOrderOverride: Int? = nil,
        usesFullCanvasPlacement: Bool = false
    ) {
        self.mode = mode
        self.normalizedCenter = normalizedCenter
        self.normalizedSize = normalizedSize
        self.normalizedPivot = normalizedPivot
        self.zOrderOverride = zOrderOverride
        self.usesFullCanvasPlacement = usesFullCanvasPlacement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(CharacterPackagePlacementMode.self, forKey: .mode)
        self.normalizedCenter = try container.decodeIfPresent(
            CharacterPackageNormalizedPoint.self,
            forKey: .normalizedCenter
        )
        self.normalizedSize = try container.decodeIfPresent(
            CharacterPackageNormalizedSize.self,
            forKey: .normalizedSize
        )
        self.normalizedPivot = try container.decodeIfPresent(
            CharacterPackageNormalizedPoint.self,
            forKey: .normalizedPivot
        )
        self.zOrderOverride = try container.decodeIfPresent(Int.self, forKey: .zOrderOverride)
        self.usesFullCanvasPlacement = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesFullCanvasPlacement
        ) ?? false
    }

    var resolvedMode: CharacterPackagePlacementMode {
        if let mode {
            return mode
        }

        return usesFullCanvasPlacement ? .fullCanvasAligned : .framed
    }

    var prefersFullCanvasPlacement: Bool {
        resolvedMode == .fullCanvasAligned
    }
}

struct CharacterPackageNormalizedPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

struct CharacterPackageNormalizedSize: Codable, Sendable, Hashable {
    var width: Double
    var height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

struct CharacterPackageAsset: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var role: CharacterPackageAssetRole
    var name: String
    var partType: PartType?
    var angle: AngleView?
    var pose: CharacterPackagePose?
    var placement: CharacterPackageAssetPlacement?
    var relativePath: String
    var tags: [String]
    var notes: String?

    init(
        id: UUID = UUID(),
        role: CharacterPackageAssetRole,
        name: String,
        partType: PartType? = nil,
        angle: AngleView? = nil,
        pose: CharacterPackagePose? = nil,
        placement: CharacterPackageAssetPlacement? = nil,
        relativePath: String,
        tags: [String] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.partType = partType
        self.angle = angle
        self.pose = pose
        self.placement = placement
        self.relativePath = relativePath
        self.tags = tags
        self.notes = notes
    }

    var normalizedRelativePath: String {
        relativePath.replacingOccurrences(of: "\\", with: "/")
    }
}

enum CharacterPackageAssetRole: String, Codable, Sendable, CaseIterable, Hashable {
    case turnaround
    case reference
    case basePose
    case expression
    case viseme
    case handPose
    case costumeOverlay
    case propOverlay
    case heroPose
    case backgroundPlate
}

enum CharacterPackagePose: String, Codable, Sendable, CaseIterable, Hashable {
    case neutral
    case frontal
    case threeQuarter
    case profile
    case seated
    case walking
    case pointing
    case action
}

struct CharacterGenerationBlueprint: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var prompt: String
    var negativePrompt: String?
    var referenceAssetIDs: [UUID]
    var outputSpecs: [CharacterPackageOutputSpec]
    var canvasSize: CharacterPackageCanvasSize?
    var seed: Int?
    var tags: [String]

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        negativePrompt: String? = nil,
        referenceAssetIDs: [UUID] = [],
        outputSpecs: [CharacterPackageOutputSpec] = [],
        canvasSize: CharacterPackageCanvasSize? = nil,
        seed: Int? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.referenceAssetIDs = referenceAssetIDs
        self.outputSpecs = outputSpecs
        self.canvasSize = canvasSize
        self.seed = seed
        self.tags = tags
    }
}

struct CharacterPackageOutputSpec: Codable, Sendable, Hashable {
    var role: CharacterPackageAssetRole
    var partType: PartType?
    var angle: AngleView?
    var pose: CharacterPackagePose?
    var count: Int

    init(
        role: CharacterPackageAssetRole,
        partType: PartType? = nil,
        angle: AngleView? = nil,
        pose: CharacterPackagePose? = nil,
        count: Int = 1
    ) {
        self.role = role
        self.partType = partType
        self.angle = angle
        self.pose = pose
        self.count = count
    }
}
