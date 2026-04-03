import Foundation

enum CharacterLookDevelopmentCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case identityAnchor
    case militaryWardrobe
    case civilianWardrobe

    var displayName: String {
        switch self {
        case .identityAnchor: "Identity Anchors"
        case .militaryWardrobe: "Military"
        case .civilianWardrobe: "Civilian / Plain Clothes"
        }
    }
}

enum CharacterLookDevelopmentCostume: String, Codable, Sendable, CaseIterable, Hashable {
    case identity
    case military
    case civilian

    var displayName: String {
        switch self {
        case .identity: "Identity"
        case .military: "Military"
        case .civilian: "Civilian"
        }
    }

    var systemImage: String {
        switch self {
        case .identity: "person.crop.square"
        case .military: "cross.case"
        case .civilian: "tshirt"
        }
    }
}

enum CharacterLookDevelopmentFraming: String, Codable, Sendable, CaseIterable, Hashable {
    case portrait
    case bust
    case upperBody
    case fullBody
    case detail

    var displayName: String {
        switch self {
        case .portrait: "Portrait"
        case .bust: "Bust"
        case .upperBody: "Upper Body"
        case .fullBody: "Full Body"
        case .detail: "Detail"
        }
    }
}

struct CharacterLookDevelopmentVariant: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var imagePath: String
    var prompt: String
    var createdAt: Date
    var aspectRatio: String
    var imageSize: String
    var model: String

    init(
        id: UUID = UUID(),
        imagePath: String,
        prompt: String,
        createdAt: Date = Date(),
        aspectRatio: String = "1:1",
        imageSize: String = "2K",
        model: String
    ) {
        self.id = id
        self.imagePath = imagePath
        self.prompt = prompt
        self.createdAt = createdAt
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? "1:1"
        imageSize = try c.decodeIfPresent(String.self, forKey: .imageSize) ?? "2K"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    }
}

struct CharacterLookDevelopmentSlot: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var key: String
    var title: String
    var category: CharacterLookDevelopmentCategory
    var costume: CharacterLookDevelopmentCostume
    var framing: CharacterLookDevelopmentFraming
    var poseNotes: String
    var prompt: String
    var recommendedAspectRatio: String
    var recommendedImageSize: String
    var variants: [CharacterLookDevelopmentVariant]
    var approvedVariantID: UUID?
    var includeApprovedVariantInReferencePack: Bool

    init(
        id: UUID = UUID(),
        key: String,
        title: String,
        category: CharacterLookDevelopmentCategory,
        costume: CharacterLookDevelopmentCostume,
        framing: CharacterLookDevelopmentFraming,
        poseNotes: String,
        prompt: String,
        recommendedAspectRatio: String = "1:1",
        recommendedImageSize: String = "2K",
        variants: [CharacterLookDevelopmentVariant] = [],
        approvedVariantID: UUID? = nil,
        includeApprovedVariantInReferencePack: Bool = true
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.category = category
        self.costume = costume
        self.framing = framing
        self.poseNotes = poseNotes
        self.prompt = prompt
        self.recommendedAspectRatio = recommendedAspectRatio
        self.recommendedImageSize = recommendedImageSize
        self.variants = variants
        self.approvedVariantID = approvedVariantID
        self.includeApprovedVariantInReferencePack = includeApprovedVariantInReferencePack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFraming = try c.decodeIfPresent(CharacterLookDevelopmentFraming.self, forKey: .framing) ?? .portrait
        let decodedKey = try c.decodeIfPresent(String.self, forKey: .key) ?? UUID().uuidString
        let decodedTitle = try c.decodeIfPresent(String.self, forKey: .title)
            ?? decodedKey.replacingOccurrences(of: "-", with: " ").capitalized

        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = decodedKey
        title = decodedTitle
        category = try c.decodeIfPresent(CharacterLookDevelopmentCategory.self, forKey: .category) ?? .identityAnchor
        costume = try c.decodeIfPresent(CharacterLookDevelopmentCostume.self, forKey: .costume) ?? .identity
        framing = decodedFraming
        poseNotes = try c.decodeIfPresent(String.self, forKey: .poseNotes) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        recommendedAspectRatio = try c.decodeIfPresent(String.self, forKey: .recommendedAspectRatio) ?? "1:1"
        recommendedImageSize = try c.decodeIfPresent(String.self, forKey: .recommendedImageSize) ?? "2K"
        variants = try c.decodeIfPresent([CharacterLookDevelopmentVariant].self, forKey: .variants) ?? []
        approvedVariantID = try c.decodeIfPresent(UUID.self, forKey: .approvedVariantID)
        includeApprovedVariantInReferencePack = try c.decodeIfPresent(Bool.self, forKey: .includeApprovedVariantInReferencePack) ?? true
    }

    var approvedVariant: CharacterLookDevelopmentVariant? {
        guard let approvedVariantID else { return variants.last }
        return variants.first(where: { $0.id == approvedVariantID }) ?? variants.last
    }
}

enum CharacterLookDevelopmentCatalog {
    static func defaultSlots(for characterName: String) -> [CharacterLookDevelopmentSlot] {
        identitySlots(for: characterName)
            + militarySlots(for: characterName)
            + civilianSlots(for: characterName)
    }

    private static func identitySlots(for characterName: String) -> [CharacterLookDevelopmentSlot] {
        [
            makeSlot(
                key: "identity-front-portrait-neutral",
                title: "Front Portrait Neutral",
                category: .identityAnchor,
                costume: .identity,
                framing: .portrait,
                poseNotes: "Head and shoulders, front facing, neutral expression.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Frame as a straight-on portrait with head and shoulders only. the subject looks directly at camera with a calm neutral expression."
            ),
            makeSlot(
                key: "identity-three-quarter-left-portrait",
                title: "Three-Quarter Left Portrait",
                category: .identityAnchor,
                costume: .identity,
                framing: .portrait,
                poseNotes: "Three-quarter portrait turned left, neutral expression.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Frame as a three-quarter portrait turned slightly left. Preserve the same face, haircut, jawline, and age as the main identity reference."
            ),
            makeSlot(
                key: "identity-three-quarter-right-portrait",
                title: "Three-Quarter Right Portrait",
                category: .identityAnchor,
                costume: .identity,
                framing: .portrait,
                poseNotes: "Three-quarter portrait turned right, neutral expression.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Frame as a three-quarter portrait turned slightly right. Preserve the same face, haircut, jawline, and age as the main identity reference."
            ),
            makeSlot(
                key: "identity-left-profile-portrait",
                title: "Left Profile Portrait",
                category: .identityAnchor,
                costume: .identity,
                framing: .portrait,
                poseNotes: "Left profile head shot for face-shape lock.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Show a clean left profile portrait. Emphasize consistent nose shape, jawline, hairline, ear placement, and neck proportions."
            ),
            makeSlot(
                key: "identity-right-profile-portrait",
                title: "Right Profile Portrait",
                category: .identityAnchor,
                costume: .identity,
                framing: .portrait,
                poseNotes: "Right profile head shot for face-shape lock.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Show a clean right profile portrait. Emphasize consistent nose shape, jawline, hairline, ear placement, and neck proportions."
            ),
            makeSlot(
                key: "identity-front-bust-determined",
                title: "Front Bust Determined",
                category: .identityAnchor,
                costume: .identity,
                framing: .bust,
                poseNotes: "Front bust shot, determined expression.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Frame a bust shot from chest up. the subject faces front with a determined, steady expression suitable for dramatic feature animation."
            ),
            makeSlot(
                key: "identity-front-bust-worried",
                title: "Front Bust Worried",
                category: .identityAnchor,
                costume: .identity,
                framing: .bust,
                poseNotes: "Front bust shot, worried expression.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Frame a bust shot from chest up. the subject faces front with a worried but grounded expression that keeps his features adult and restrained."
            ),
            makeSlot(
                key: "identity-front-bust-exhausted",
                title: "Front Bust Exhausted",
                category: .identityAnchor,
                costume: .identity,
                framing: .bust,
                poseNotes: "Front bust shot, exhausted expression.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Frame a bust shot from chest up. the subject faces front with exhausted eyes and tension in the mouth while keeping the exact same identity."
            ),
            makeSlot(
                key: "identity-upper-body-hands-visible",
                title: "Upper Body Hands Visible",
                category: .identityAnchor,
                costume: .identity,
                framing: .upperBody,
                poseNotes: "Upper body with hands visible for proportion checks.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt with no satchel or outer gear",
                shotInstruction: "Show the subject from mid-thigh or waist up with both hands visible in frame so hand size, shoulder width, and torso proportions can be checked."
            ),
            makeSlot(
                key: "identity-full-body-neutral-silhouette",
                title: "Full-Body Neutral Silhouette",
                category: .identityAnchor,
                costume: .identity,
                framing: .fullBody,
                poseNotes: "Full body neutral standing pose to lock overall silhouette.",
                characterName: characterName,
                costumeNotes: "simple neutral charcoal long-sleeve shirt, plain trousers, and simple shoes with no satchel or costume accessories",
                shotInstruction: "Show the subject full body, head to toe, centered in a neutral standing pose with readable silhouette and adult realistic proportions."
            ),
        ]
    }

    private static func militarySlots(for characterName: String) -> [CharacterLookDevelopmentSlot] {
        [
            makeSlot(key: "military-front-full-body-neutral", title: "Front Full-Body Neutral", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Front full-body neutral standing pose.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body from head to toe, front view, centered, in a neutral standing pose for canonical costume lock."),
            makeSlot(key: "military-three-quarter-left-full-body", title: "Three-Quarter Left Full Body", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Three-quarter left full-body turnaround view.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body in a three-quarter left view, standing in a neutral pose with clean readable costume shapes."),
            makeSlot(key: "military-three-quarter-right-full-body", title: "Three-Quarter Right Full Body", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Three-quarter right full-body turnaround view.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body in a three-quarter right view, standing in a neutral pose with clean readable costume shapes."),
            makeSlot(key: "military-left-side-full-body", title: "Left Side Full Body", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Left side profile full-body turnaround view.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body in a clean left side profile to lock the silhouette, satchel placement, boot shape, and body proportions."),
            makeSlot(key: "military-back-full-body", title: "Back Full Body", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Back view full-body turnaround view.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body from the back to lock jacket back shape, shoulder profile, satchel strap routing, and silhouette."),
            makeSlot(key: "military-standing-weight-left", title: "Standing Weight Left", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Relaxed standing pose with weight on left leg.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body standing with his weight shifted naturally onto the left leg while preserving exact costume and body proportions."),
            makeSlot(key: "military-standing-weight-right", title: "Standing Weight Right", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Relaxed standing pose with weight on right leg.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body standing with his weight shifted naturally onto the right leg while preserving exact costume and body proportions."),
            makeSlot(key: "military-walking-stride", title: "Walking Stride", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Full-body walking pose for locomotion reference.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body mid-walk with a grounded practical stride suitable for animation blocking. Keep both feet visible and the satchel behavior believable."),
            makeSlot(key: "military-kneeling-aid", title: "Kneeling Aid Pose", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Kneeling pose as if assisting someone.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject in a full-body kneeling pose that suggests he is helping or checking on someone just out of frame. Keep the military identity grounded and serious."),
            makeSlot(key: "military-reaching-satchel", title: "Reaching to Satchel", category: .militaryWardrobe, costume: .military, framing: .fullBody, poseNotes: "Full-body pose reaching for satchel or pouch.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject full body reaching toward his satchel so strap placement, pouch position, and arm silhouette can be tested."),
            makeSlot(key: "military-front-torso-costume-check", title: "Front Torso Costume Check", category: .militaryWardrobe, costume: .military, framing: .upperBody, poseNotes: "Front torso crop for pocket, seam, and strap consistency.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Crop to upper body and torso from the front. Emphasize pockets, seams, satchel strap position, scarf wrap, and chest silhouette."),
            makeSlot(key: "military-three-quarter-torso-check", title: "Three-Quarter Torso Check", category: .militaryWardrobe, costume: .military, framing: .upperBody, poseNotes: "Three-quarter torso crop for costume structure.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Crop to upper body in a three-quarter angle to verify jacket structure, scarf layering, and satchel strap depth."),
            makeSlot(key: "military-seated-medium-shot", title: "Seated Medium Shot", category: .militaryWardrobe, costume: .military, framing: .upperBody, poseNotes: "Seated medium shot for practical acting posture.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject seated in a simple medium framing with readable posture and consistent costume folds. Keep the background neutral and nondistracting."),
            makeSlot(key: "military-satchel-strap-placement", title: "Satchel Strap Placement", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Detail crop focused on strap routing and satchel placement.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Create a detail-oriented crop focused on the torso, satchel strap, bag attachment points, and how the bag sits on the body."),
            makeSlot(key: "military-scarf-collar-neckline", title: "Scarf / Collar / Neckline", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Detail crop of scarf wrap, collar, and neckline treatment.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show a close costume study of the subject's scarf, collar, neckline, and upper jacket opening so those details stay consistent in later assets."),
            makeSlot(key: "military-boots-lower-body", title: "Boots / Lower Body", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Lower-body crop for trousers, boots, and hem details.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Focus on the subject's lower body from waist to boots, emphasizing trouser break, boot silhouette, and cuff consistency."),
            makeSlot(key: "military-sleeves-cuffs-gloves", title: "Sleeves / Cuffs / Gloves", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Detail crop for sleeve roll, cuff treatment, and handwear.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Focus on sleeves, cuffs, gloves or bare hands, and forearm silhouette to lock those functional details."),
            makeSlot(key: "military-satchel-detail", title: "Satchel Detail", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Detail crop of bag construction and markings.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show a detail-oriented crop of the subject's satchel, including flap shape, wear, pockets, and restrained military markings."),
            makeSlot(key: "military-back-silhouette-jacket", title: "Back Silhouette / Jacket", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Back torso crop to lock shoulder and jacket silhouette.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the back torso and shoulders so jacket drape, back seam structure, and silhouette can be locked."),
            makeSlot(key: "military-hands-kit-handling", title: "Hands Handling Field Kit", category: .militaryWardrobe, costume: .military, framing: .detail, poseNotes: "Hand and prop handling study for field-kit interaction.", characterName: characterName, costumeNotes: militaryCostumeNotes, shotInstruction: "Show the subject's hands interacting with field gear or the satchel in a clean readable detail shot for hand-acting reference."),
        ]
    }

    private static func civilianSlots(for characterName: String) -> [CharacterLookDevelopmentSlot] {
        [
            makeSlot(key: "civilian-front-full-body-neutral", title: "Front Full-Body Neutral", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Front full-body neutral standing pose.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body from head to toe, front view, centered, in a neutral standing pose for canonical civilian costume lock."),
            makeSlot(key: "civilian-three-quarter-left-full-body", title: "Three-Quarter Left Full Body", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Three-quarter left full-body turnaround view.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body in a three-quarter left view, standing in a neutral pose with clean readable civilian costume shapes."),
            makeSlot(key: "civilian-three-quarter-right-full-body", title: "Three-Quarter Right Full Body", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Three-quarter right full-body turnaround view.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body in a three-quarter right view, standing in a neutral pose with clean readable civilian costume shapes."),
            makeSlot(key: "civilian-left-side-full-body", title: "Left Side Full Body", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Left side profile full-body turnaround view.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body in a clean left side profile to lock the silhouette, outerwear length, trouser line, and body proportions."),
            makeSlot(key: "civilian-back-full-body", title: "Back Full Body", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Back view full-body turnaround view.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body from the back to lock jacket or shirt drape, shoulder profile, and silhouette."),
            makeSlot(key: "civilian-standing-weight-left", title: "Standing Weight Left", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Relaxed standing pose with weight on left leg.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body standing with his weight shifted naturally onto the left leg while preserving exact civilian costume and body proportions."),
            makeSlot(key: "civilian-standing-weight-right", title: "Standing Weight Right", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Relaxed standing pose with weight on right leg.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body standing with his weight shifted naturally onto the right leg while preserving exact civilian costume and body proportions."),
            makeSlot(key: "civilian-walking-relaxed", title: "Walking Relaxed", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Relaxed full-body walking pose.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body mid-walk in a grounded relaxed stride suitable for civilian blocking. Keep both feet visible and the costume silhouette readable."),
            makeSlot(key: "civilian-seated-contemplative", title: "Seated Contemplative", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Seated pose for quieter acting beats.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject seated in a grounded contemplative pose suitable for quieter dramatic beats, keeping costume folds believable and clear."),
            makeSlot(key: "civilian-reaching-doorway", title: "Reaching / Doorway Action", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Full-body reaching pose for blocking tests.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body reaching slightly forward as if opening a door or accepting an object, with clean readable silhouette and grounded acting."),
            makeSlot(key: "civilian-front-torso-costume-check", title: "Front Torso Costume Check", category: .civilianWardrobe, costume: .civilian, framing: .upperBody, poseNotes: "Front torso crop for shirt/jacket consistency.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Crop to upper body and torso from the front. Emphasize shirt opening, jacket line, scarf placement, and chest silhouette."),
            makeSlot(key: "civilian-three-quarter-torso-check", title: "Three-Quarter Torso Check", category: .civilianWardrobe, costume: .civilian, framing: .upperBody, poseNotes: "Three-quarter torso crop for layering consistency.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Crop to upper body in a three-quarter angle to verify shirt layering, jacket structure, and scarf depth."),
            makeSlot(key: "civilian-layered-clothing-check", title: "Layered Clothing Check", category: .civilianWardrobe, costume: .civilian, framing: .upperBody, poseNotes: "Upper-body crop for civilian layering and drape.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show an upper-body costume study that clarifies the civilian layering, how the shirt sits under outerwear, and the overall garment drape."),
            makeSlot(key: "civilian-neckline-scarf-check", title: "Neckline / Scarf Check", category: .civilianWardrobe, costume: .civilian, framing: .detail, poseNotes: "Detail crop of neckline and scarf handling.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show a close costume study of the neckline, scarf, and collar treatment so those details remain consistent."),
            makeSlot(key: "civilian-outerwear-open-closed", title: "Outerwear Open / Closed", category: .civilianWardrobe, costume: .civilian, framing: .detail, poseNotes: "Detail crop focused on jacket opening and closure logic.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show a torso-focused study clarifying how the outer layer looks when open or partially closed, without changing the subject's identity."),
            makeSlot(key: "civilian-shoes-lower-body", title: "Shoes / Lower Body", category: .civilianWardrobe, costume: .civilian, framing: .detail, poseNotes: "Lower-body crop for trousers and footwear.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Focus on the subject's lower body from waist to shoes, emphasizing trouser break, footwear silhouette, and cuff consistency."),
            makeSlot(key: "civilian-sleeves-cuffs-hands", title: "Sleeves / Cuffs / Hands", category: .civilianWardrobe, costume: .civilian, framing: .detail, poseNotes: "Detail crop for civilian sleeve treatment and hands.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Focus on sleeves, cuffs, and hands so forearm silhouette and civilian clothing details stay locked."),
            makeSlot(key: "civilian-back-silhouette-jacket-drape", title: "Back Silhouette / Jacket Drape", category: .civilianWardrobe, costume: .civilian, framing: .detail, poseNotes: "Back torso crop to lock drape and silhouette.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the back torso and shoulders so jacket or shirt drape, seam placement, and silhouette can be locked."),
            makeSlot(key: "civilian-bag-prop-handling", title: "Bag / Prop Handling", category: .civilianWardrobe, costume: .civilian, framing: .detail, poseNotes: "Hand and bag interaction study for civilian scenes.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject's hands interacting with a simple civilian bag, cloth bundle, or similarly grounded prop in a clean readable detail shot."),
            makeSlot(key: "civilian-full-body-silhouette-variant", title: "Full-Body Silhouette Variant", category: .civilianWardrobe, costume: .civilian, framing: .fullBody, poseNotes: "Second neutral full-body silhouette check with slight posture change.", characterName: characterName, costumeNotes: civilianCostumeNotes, shotInstruction: "Show the subject full body in a second neutral silhouette-check pose with a subtle posture shift, preserving the exact same civilian wardrobe and proportions."),
        ]
    }

    private static let militaryCostumeNotes =
        "\(CharacterPromptWorldContext.militaryClothing), optional practical scarf, restrained insignia, no shiny tactical-hero styling"

    private static let civilianCostumeNotes =
        "\(CharacterPromptWorldContext.civilianClothing), no flashy hero styling"

    private static func makeSlot(
        key: String,
        title: String,
        category: CharacterLookDevelopmentCategory,
        costume: CharacterLookDevelopmentCostume,
        framing: CharacterLookDevelopmentFraming,
        poseNotes: String,
        characterName: String,
        costumeNotes: String,
        shotInstruction: String
    ) -> CharacterLookDevelopmentSlot {
        CharacterLookDevelopmentSlot(
            key: key,
            title: title,
            category: category,
            costume: costume,
            framing: framing,
            poseNotes: poseNotes,
            prompt: """
            Use the supplied reference images to preserve the exact identity of this character: same face shape, apparent age, hairline, hairstyle, skin tone, body proportions, and mature emotional tone. Create one square 1:1 character look-development image with a pure white studio background and no scenic storytelling. \(shotInstruction) Costume specification: \(costumeNotes). If clothing or styling cues are visible, make them feel native to \(CharacterPromptWorldContext.settingSummary). Keep the image centered, readable, and designed for later character-asset generation. Maintain a serious adult dramatic tone. No 3D render, no CGI, no cute stylization, no chibi, no oversized anime eyes, no text, no watermark, no fake insignia, no distorted anatomy, no broken hands.
            """,
            recommendedAspectRatio: "1:1",
            recommendedImageSize: "2K"
        )
    }
}
