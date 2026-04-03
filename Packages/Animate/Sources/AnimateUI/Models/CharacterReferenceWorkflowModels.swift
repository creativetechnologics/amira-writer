import Foundation

enum CharacterPromptWorldContext {
    static let settingSummary =
        "a grounded early-2000s Afghanistan war drama with dusty Afghan city streets and villages, concrete and mud-brick buildings, district clinics, checkpoints, humanitarian and military presence, realistic modern fabrics and gear, and a serious adult dramatic tone"

    static let militaryClothing =
        "a grounded early-2000s American military silhouette in Afghanistan with modern desert camouflage or muted sand combat clothing, cargo trousers, tan combat boots, practical nylon pouches or satchels, restrained utility details, and believable early-2000s field-uniform construction"

    static let civilianClothing =
        "grounded civilian clothing suitable for Afghanistan in the early 2000s, using modest practical layers, believable local fabrics, worn trousers, durable shoes or boots, simple scarves or overshirts, and no military uniform or tactical gear"

    static let cityClinicEnvironment =
        "a dusty urban street near a district clinic at pre-dawn first light, with plaster, concrete, mud-brick walls, corrugated awnings, doorway light, restrained humanitarian and military presence, and grounded Afghan village-and-city realism"

    static let avoidHistoricalWarStyling =
        "Avoid fantasy, science fiction, World War I styling, World War II styling, wool tunics, leather cross straps, puttees, Sam Browne belts, vintage tailoring, and old-fashioned military costumes."
}

enum CharacterReferencePose: String, Codable, Sendable, CaseIterable, Hashable {
    case frontNeutral
    case quarterLeft
    case quarterRight
    case back
    case leftProfile
    case rightProfile

    var title: String {
        switch self {
        case .frontNeutral: "Front Neutral"
        case .quarterLeft: "Quarter Left"
        case .quarterRight: "Quarter Right"
        case .back: "Back"
        case .leftProfile: "Left Profile"
        case .rightProfile: "Right Profile"
        }
    }

    var gridLabel: String {
        switch self {
        case .frontNeutral: "1:1"
        case .quarterLeft: "1:2"
        case .quarterRight: "1:3"
        case .back: "2:1"
        case .leftProfile: "2:2"
        case .rightProfile: "2:3"
        }
    }

    var poseInstruction: String {
        switch self {
        case .frontNeutral:
            "front neutral, looking directly at camera"
        case .quarterLeft:
            "quarter-turn left, facing screen-left, nose pointing screen-left"
        case .quarterRight:
            "quarter-turn right, facing screen-right, nose pointing screen-right"
        case .back:
            "back view only"
        case .leftProfile:
            "true left side profile facing screen-left"
        case .rightProfile:
            "true right side profile facing screen-right"
        }
    }
}

struct CharacterPoseSlot: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var key: String
    var title: String
    var pose: CharacterReferencePose
    var prompt: String
    var notes: String
    var recommendedAspectRatio: String
    var recommendedImageSize: String
    var variants: [CharacterLookDevelopmentVariant]
    var approvedVariantID: UUID?

    init(
        id: UUID = UUID(),
        key: String,
        title: String,
        pose: CharacterReferencePose,
        prompt: String,
        notes: String,
        recommendedAspectRatio: String = "1:1",
        recommendedImageSize: String = "4K",
        variants: [CharacterLookDevelopmentVariant] = [],
        approvedVariantID: UUID? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.pose = pose
        self.prompt = prompt
        self.notes = notes
        self.recommendedAspectRatio = recommendedAspectRatio
        self.recommendedImageSize = recommendedImageSize
        self.variants = variants
        self.approvedVariantID = approvedVariantID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPose = try c.decodeIfPresent(CharacterReferencePose.self, forKey: .pose) ?? .frontNeutral
        let decodedKey = try c.decodeIfPresent(String.self, forKey: .key) ?? decodedPose.rawValue

        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = decodedKey
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? decodedPose.title
        pose = decodedPose
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        recommendedAspectRatio = try c.decodeIfPresent(String.self, forKey: .recommendedAspectRatio) ?? "1:1"
        recommendedImageSize = try c.decodeIfPresent(String.self, forKey: .recommendedImageSize) ?? "4K"
        variants = try c.decodeIfPresent([CharacterLookDevelopmentVariant].self, forKey: .variants) ?? []
        approvedVariantID = try c.decodeIfPresent(UUID.self, forKey: .approvedVariantID)
    }

    var approvedVariant: CharacterLookDevelopmentVariant? {
        guard let approvedVariantID else { return variants.last }
        return variants.first(where: { $0.id == approvedVariantID }) ?? variants.last
    }
}

struct CharacterAccessorySlot: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var key: String
    var title: String
    var prompt: String
    var notes: String
    var recommendedAspectRatio: String
    var recommendedImageSize: String
    var variants: [CharacterLookDevelopmentVariant]
    var approvedVariantID: UUID?

    init(
        id: UUID = UUID(),
        key: String,
        title: String,
        prompt: String,
        notes: String,
        recommendedAspectRatio: String = "1:1",
        recommendedImageSize: String = "4K",
        variants: [CharacterLookDevelopmentVariant] = [],
        approvedVariantID: UUID? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.prompt = prompt
        self.notes = notes
        self.recommendedAspectRatio = recommendedAspectRatio
        self.recommendedImageSize = recommendedImageSize
        self.variants = variants
        self.approvedVariantID = approvedVariantID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try c.decodeIfPresent(String.self, forKey: .key) ?? UUID().uuidString

        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = decodedKey
        title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? decodedKey.replacingOccurrences(of: "-", with: " ").capitalized
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        recommendedAspectRatio = try c.decodeIfPresent(String.self, forKey: .recommendedAspectRatio) ?? "1:1"
        recommendedImageSize = try c.decodeIfPresent(String.self, forKey: .recommendedImageSize) ?? "4K"
        variants = try c.decodeIfPresent([CharacterLookDevelopmentVariant].self, forKey: .variants) ?? []
        approvedVariantID = try c.decodeIfPresent(UUID.self, forKey: .approvedVariantID)
    }

    var approvedVariant: CharacterLookDevelopmentVariant? {
        guard let approvedVariantID else { return variants.last }
        return variants.first(where: { $0.id == approvedVariantID }) ?? variants.last
    }
}

struct CharacterCostumeReferenceSet: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var notes: String
    var sheetPrompt: String
    var sheetVariants: [CharacterLookDevelopmentVariant]
    var approvedSheetVariantID: UUID?
    var fullBodySlots: [CharacterPoseSlot]
    var accessorySlots: [CharacterAccessorySlot]

    init(
        id: UUID = UUID(),
        name: String,
        notes: String,
        sheetPrompt: String,
        sheetVariants: [CharacterLookDevelopmentVariant] = [],
        approvedSheetVariantID: UUID? = nil,
        fullBodySlots: [CharacterPoseSlot],
        accessorySlots: [CharacterAccessorySlot]
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.sheetPrompt = sheetPrompt
        self.sheetVariants = sheetVariants
        self.approvedSheetVariantID = approvedSheetVariantID
        self.fullBodySlots = fullBodySlots
        self.accessorySlots = accessorySlots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sheetPrompt = try c.decodeIfPresent(String.self, forKey: .sheetPrompt) ?? ""
        sheetVariants = try c.decodeIfPresent([CharacterLookDevelopmentVariant].self, forKey: .sheetVariants) ?? []
        approvedSheetVariantID = try c.decodeIfPresent(UUID.self, forKey: .approvedSheetVariantID)
        fullBodySlots = try c.decodeIfPresent([CharacterPoseSlot].self, forKey: .fullBodySlots) ?? []
        accessorySlots = try c.decodeIfPresent([CharacterAccessorySlot].self, forKey: .accessorySlots) ?? []
    }

    var approvedSheetVariant: CharacterLookDevelopmentVariant? {
        guard let approvedSheetVariantID else { return sheetVariants.last }
        return sheetVariants.first(where: { $0.id == approvedSheetVariantID }) ?? sheetVariants.last
    }
}

enum CharacterReferenceWorkflowCatalog {
    static let defaultMasterSheetAspectRatio = "16:9"
    static let defaultMasterSheetImageSize = "4K"
    static let sectionSheetAspectRatio = "1:1"
    static let sectionSheetImageSize = "4K"

    static func defaultMasterSheetPrompt(for characterName: String, gender: CharacterGenderType = .person) -> String {
        let clothingDirection: String
        switch gender {
        case .female:
            clothingDirection = "The character is wearing only a plain fitted t-shirt and simple boxer-brief-style shorts — modest, minimal coverage for a body-proportion reference sheet. No costume, no accessories, no shoes."
        case .male:
            clothingDirection = "The character is wearing only plain black boxer briefs — minimal coverage for a body-proportion reference sheet. No shirt, no costume, no accessories, no shoes."
        case .person:
            clothingDirection = "The character is wearing only minimal neutral undergarments — minimal coverage for a body-proportion reference sheet. No costume, no accessories, no shoes."
        }

        return """
        The first reference image is the primary identity anchor. Preserve every identifying detail exactly: same face shape, same eye shape and color, same nose, same jawline, same hairline, same hair color and texture, same hairstyle, same skin tone, same apparent age, same body proportions, and same overall build. Do not change, lighten, darken, or reinterpret any of these features.

        Create one single polished high-resolution 4K character reference sheet as a professional animation model sheet on a pure white background. This must be the same exact character in every panel with identical face, hairstyle, skin tone, hair color, and body proportions.

        \(clothingDirection)

        Layout: one wide unlabeled 16:9 sheet with fourteen clearly separated panels arranged in two perfectly aligned rows of seven columns.
        Top row, full-body panels left to right: front neutral, front smiling, three-quarter left, three-quarter right, left profile, right profile, back.
        Bottom row, close-up panels left to right aligned directly beneath the matching full-body panel: face front neutral close-up, face front smiling close-up, face three-quarter left close-up, face three-quarter right close-up, face left profile close-up, face right profile close-up, back of head close-up.

        Style: mature 2D anime feature-film realism, serious adult dramatic tone, clean elegant ink linework, restrained cel shading, painterly but controlled fills, production-friendly model-sheet clarity.

        Use neutral studio lighting, crisp readability, balanced spacing, and consistent scale. Keep the sheet unlabeled. No scenic environment, no extra characters, no props, no watermark, no typography, no text, no labels, no 3D, no CGI, no chibi, no cute stylization, no oversized anime eyes, no broken hands, no distorted anatomy, no photorealistic rendering.
        """
    }

    static func legacyDefaultMasterSheetPrompt(for characterName: String) -> String {
        """
        Image 1 is the exact identity reference for this character. Create one polished high-resolution unlabeled character reference sheet on a pure white background. Keep the same exact face, hair, body proportions, costume logic, and silhouette across every panel. The sheet may contain front neutral, front smiling, quarter-turns, side profiles, back view, and supporting close-ups. The goal is to produce a single beautiful master reference sheet that can later be used as the main ingredient for more precise pose generations. Keep the styling mature, clean, and production-friendly, and if clothing is visible make it feel native to \(CharacterPromptWorldContext.settingSummary). No scenic environment, no extra characters, no text, no watermark, no 3D, no CGI, no chibi, no cute stylization, no distorted anatomy.
        """
    }

    static func defaultHeadSlots(for characterName: String) -> [CharacterPoseSlot] {
        CharacterReferencePose.allCases.map { pose in
            CharacterPoseSlot(
                key: "head-\(pose.rawValue)",
                title: pose.title,
                pose: pose,
                prompt: headPrompt(for: pose, characterName: characterName),
                notes: "Head-only neutral turnaround pose."
            )
        }
    }

    static func defaultHeadSheetPrompt(for characterName: String) -> String {
        """
        Use the supplied references to preserve the exact identity of this character. Create one square 1:1 professional head turnaround sheet on a pure white studio background. Show the same exact character as six evenly spaced close-up head panels in a 2x3 grid. Row 1 left to right: front neutral, quarter-turn left, quarter-turn right. Row 2 left to right: back of head, left profile, right profile. Every panel must remain neutral, costume-free, and tightly focused on the head and neck only. No labels, no text, no watermark, no extra characters. Mature 2D anime realism, clean elegant linework, restrained cel shading, production-friendly clarity.
        """
    }

    static func defaultCostumeSets(for characterName: String) -> [CharacterCostumeReferenceSet] {
        [
            makeCostumeSet(
                characterName: characterName,
                name: "Military",
                notes: """
                \(CharacterPromptWorldContext.militaryClothing)
                """
            ),
            makeCostumeSet(
                characterName: characterName,
                name: "Plain Clothes",
                notes: """
                \(CharacterPromptWorldContext.civilianClothing)
                """
            ),
        ]
    }

    static func makeCostumeSet(
        characterName: String,
        name: String,
        notes: String
    ) -> CharacterCostumeReferenceSet {
        CharacterCostumeReferenceSet(
            name: name,
            notes: notes,
            sheetPrompt: fullBodySheetPrompt(characterName: characterName, costumeName: name, costumeNotes: notes),
            fullBodySlots: CharacterReferencePose.allCases.map { pose in
                CharacterPoseSlot(
                    key: "\(slug(from: name))-fullbody-\(pose.rawValue)",
                    title: pose.title,
                    pose: pose,
                    prompt: fullBodyPrompt(for: pose, characterName: characterName, costumeNotes: notes),
                    notes: "\(name) full-body turnaround pose."
                )
            },
            accessorySlots: defaultAccessorySlots(characterName: characterName, costumeName: name, costumeNotes: notes)
        )
    }

    static func defaultAccessorySlots(
        characterName: String,
        costumeName: String,
        costumeNotes: String
    ) -> [CharacterAccessorySlot] {
        [
            CharacterAccessorySlot(
                key: "\(slug(from: costumeName))-accessory-bag",
                title: "Field Bag",
                prompt: accessoryPrompt(
                    title: "field bag or satchel",
                    characterName: characterName,
                    costumeName: costumeName,
                    costumeNotes: costumeNotes
                ),
                notes: "Primary satchel / pouch reference."
            ),
            CharacterAccessorySlot(
                key: "\(slug(from: costumeName))-accessory-gloves",
                title: "Gloves / Hands",
                prompt: accessoryPrompt(
                    title: "gloves and hands",
                    characterName: characterName,
                    costumeName: costumeName,
                    costumeNotes: costumeNotes
                ),
                notes: "Handwear and hand silhouette reference."
            ),
            CharacterAccessorySlot(
                key: "\(slug(from: costumeName))-accessory-prop",
                title: "Primary Prop",
                prompt: accessoryPrompt(
                    title: "primary prop",
                    characterName: characterName,
                    costumeName: costumeName,
                    costumeNotes: costumeNotes
                ),
                notes: "Prop / tool / handheld item reference."
            ),
        ]
    }

    static func headPrompt(for pose: CharacterReferencePose, characterName: String) -> String {
        """
        Use the supplied references to preserve the exact identity of this character: same face shape, same apparent age, same hairline, same hairstyle, same skin tone, same stubble, same eyes, and same neck proportions. Create one clean head-only close-up on a pure white studio background. Pose requirement: \(pose.poseInstruction). Keep the expression neutral. No costume, no scarf, no collar, no visible shirt beyond a minimal neutral neck base. Mature 2D anime realism, clean elegant linework, restrained cel shading, production-friendly clarity, no text, no watermark, no distorted anatomy.
        """
    }

    static func fullBodyPrompt(
        for pose: CharacterReferencePose,
        characterName: String,
        costumeNotes: String
    ) -> String {
        """
        The first reference image is the primary identity anchor — it defines the exact character who must appear in this output. Preserve every identifying detail exactly: same face shape, same eye shape and color, same nose, same jawline, same hairline, same hair color and texture, same hairstyle, same skin tone, same apparent age, same body proportions, and same overall build. Do not change, lighten, darken, or reinterpret any of these features.

        Create one full-body neutral turnaround image on a pure white studio background. Pose requirement: \(pose.poseInstruction). Show the full body from head to boots. Keep the expression neutral. Costume specification: \(costumeNotes). Mature 2D anime realism, clean elegant linework, restrained cel shading, production-friendly clarity, no scenic environment, no extra characters, no text, no watermark, no distorted anatomy.
        """
    }

    static func fullBodySheetPrompt(
        characterName: String,
        costumeName: String,
        costumeNotes: String
    ) -> String {
        """
        The first reference image is the primary identity anchor — it defines the exact character who must appear in every panel of this sheet. Preserve every identifying detail exactly: same face shape, same eye shape and color, same nose, same jawline, same hairline, same hair color and texture, same hairstyle, same skin tone, same apparent age, same body proportions, and same overall build. Do not change, lighten, darken, or reinterpret any of these features.

        Create one square 1:1 professional full-body turnaround sheet wearing the \(costumeName) wardrobe on a pure white studio background. Show the same exact character in six evenly spaced full-body panels in a 2x3 grid. Row 1 left to right: front neutral, quarter-turn left, quarter-turn right. Row 2 left to right: back view, left profile, right profile. Keep the expression neutral in every panel. Show the full body from head to footwear in every panel. Costume specification: \(costumeNotes). No labels, no text, no watermark, no scenic background, no extra characters. Mature 2D anime realism, clean elegant linework, restrained cel shading, production-friendly clarity.
        """
    }

    static func accessoryPrompt(
        title: String,
        characterName: String,
        costumeName: String,
        costumeNotes: String
    ) -> String {
        """
        The first reference image is the primary identity anchor — preserve the exact character identity including face, hair color, skin tone, and proportions. Create one clean accessory reference image focused on the \(title) as worn with the \(costumeName) costume. Keep the design consistent with this costume: \(costumeNotes). Pure white studio background, mature 2D anime realism, clean elegant linework, restrained cel shading, production-friendly clarity, no text, no watermark, no extra characters.
        """
    }

    static func slug(from value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
