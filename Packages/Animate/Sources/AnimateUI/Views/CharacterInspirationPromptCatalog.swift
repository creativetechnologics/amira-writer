import Foundation

@available(macOS 26.0, *)
struct CharacterInspirationPromptSpec: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let category: String
    let poseInstruction: String
}

@available(macOS 26.0, *)
enum CharacterInspirationGenerationMode: String, Hashable, Sendable {
    case immediate
    case batch
}

@available(macOS 26.0, *)
enum CharacterInspirationPromptCatalog {
    static let defaultAspectRatio = "1:1"
    static let defaultImageSize = "2K"

    static let allSpecs: [CharacterInspirationPromptSpec] = [
        .init(id: "front_view_neutral", title: "Front Neutral", category: "front_view", poseInstruction: "front facing portrait of the reference character, neutral expression, looking directly at camera, relaxed face, natural upright head position"),
        .init(id: "front_view_soft_smile_head_tilt", title: "Front Soft Smile", category: "front_view", poseInstruction: "front facing portrait of the reference character, soft natural smile, head slightly tilted to the right, looking directly at camera, relaxed face"),
        .init(id: "front_view_serious_chin_lowered", title: "Front Serious", category: "front_view", poseInstruction: "front facing portrait of the reference character, serious neutral expression, chin slightly lowered, eyes looking directly at camera, relaxed face"),
        .init(id: "close_up_neutral", title: "Close-Up Neutral", category: "close_up", poseInstruction: "close up portrait of the reference character, neutral expression, looking directly at camera, upright head position, face fills frame"),
        .init(id: "close_up_serious_head_turn", title: "Close-Up Serious", category: "close_up", poseInstruction: "close up portrait of the reference character, serious expression, head turned slightly a few degrees to the right while eyes still looking at camera, face fills frame"),
        .init(id: "full_body_front_straight_posture", title: "Full Body Front Straight", category: "full_body_front", poseInstruction: "full body portrait of the reference character, neutral expression, standing upright, facing camera directly, arms relaxed naturally"),
        .init(id: "full_body_front_weight_shift", title: "Full Body Front Natural Stance", category: "full_body_front", poseInstruction: "full body portrait of the reference character, neutral expression, standing facing camera, slight natural weight shift to one leg, relaxed believable stance"),
        .init(id: "full_body_left_upright", title: "Full Body Left Upright", category: "full_body_left", poseInstruction: "full body portrait of the reference character, facing left side, neutral expression, upright posture, arms relaxed naturally"),
        .init(id: "full_body_right_upright", title: "Full Body Right Upright", category: "full_body_right", poseInstruction: "full body portrait of the reference character, facing right side, neutral expression, upright posture, arms relaxed naturally"),
        .init(id: "full_body_back_upright", title: "Full Body Back Upright", category: "full_body_back", poseInstruction: "full body portrait of the reference character, facing away from camera, back view, upright posture, arms relaxed naturally"),
        .init(id: "fortyfive_left_upright", title: "45° Left Upright", category: "fortyfive_left", poseInstruction: "45 degree angle portrait of the reference character facing left, neutral expression, upright head position, eyes looking forward"),
        .init(id: "fortyfive_right_upright", title: "45° Right Upright", category: "fortyfive_right", poseInstruction: "45 degree angle portrait of the reference character facing right, neutral expression, upright head position, eyes looking forward"),
        .init(id: "profile_left_upright", title: "Profile Left Upright", category: "profile_left", poseInstruction: "strict side profile portrait of the reference character facing left, neutral expression, upright head position, eyes looking forward"),
        .init(id: "profile_right_upright", title: "Profile Right Upright", category: "profile_right", poseInstruction: "strict side profile portrait of the reference character facing right, neutral expression, upright head position, eyes looking forward"),
        .init(id: "walking_toward_camera", title: "Walking Toward Camera", category: "walking", poseInstruction: "medium wide portrait of the reference character walking naturally toward camera, neutral expression, arms relaxed, feet visible, believable gait in an outdoor setting"),
    ]

    static func prompt(
        for spec: CharacterInspirationPromptSpec,
        character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe,
        specIndex: Int = 0
    ) -> String {
        let subject = subjectDescriptor(for: character)
        let shortSubject = shortSubjectDescriptor(for: character)
        let environments = CharacterPromptWorldContext.variedEnvironments
        let seed = abs(character.id.uuidString.hashValue)
        let environment = environments[(specIndex + seed) % environments.count]
        let amiraAnchor = CharacterPromptWorldContext.amiraWorldAnchor
        return """
        TASK: Generate a brand-new photorealistic cinematic documentary frame set in the world of Amira. This is a NEW image — do NOT reproduce, edit, or copy any reference image. The reference images are provided ONLY for facial identity lock.

        IDENTITY LOCK (from reference images): Retain the facial identity of \(subject) — same face shape, eyes, nose, mouth, hairline, skin tone, and apparent age as shown in the reference images. Do NOT use the references for composition, background, framing, lighting, crop, pose, clothing details, or any other visual element. The references are identity-only.

        NEW COMPOSITION (this is required — ignore any composition cues from references): \(spec.poseInstruction). The pose, camera angle, framing, background, lighting, and crop must all come from this instruction, NOT from any reference image.

        WARDROBE: \(wardrobePrompt(for: character, wardrobe: wardrobe))

        SETTING (must be clearly visible in the background unless this is a tight face close-up): Place \(shortSubject) in \(environment). This location exists inside the world of Amira — \(amiraAnchor). The background must feel like Amira specifically, not a generic desert military city or a Hollywood war-movie backlot. Vary environmental details (architecture, vegetation, weather, time of day, foreground objects) so this frame does NOT look like the other frames in this batch.

        RENDERING: bright natural daylight, clean true-to-life color, authentic fabric texture, realistic skin pores, sharp face detail, shallow depth of field, well-lit and clear.

        NEGATIVE: no European stone village, no Western movie backlot, no generic "desert warzone" stock look, no identical repeated background across frames, no readable nametag, no gibberish text, no fake patches, no shiny tactical-hero vest, no oversized body armor, no text, no watermark, no copying of the reference image composition or background, no dark moody underexposed lighting.
        """
    }

    private static func wardrobePrompt(
        for character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe
    ) -> String {
        let subject = shortSubjectDescriptor(for: character)
        switch wardrobe {
        case .soldier:
            return "\(subject.capitalized) is wearing \(CharacterPromptWorldContext.militaryClothing), with weathered utility layers, sleeves rolled, subtle local scarf or village-fabric detail, grounded and believable, and no tactical-hero styling."
        case .civilian:
            return "\(subject.capitalized) is wearing \(CharacterPromptWorldContext.civilianClothing), with practical everyday layers, believable local fabrics, and a modest lived-in silhouette."
        }
    }

    private static func subjectDescriptor(for character: AnimationCharacter) -> String {
        if let age = character.age, age > 0 {
            return "this \(age)-year-old \(character.genderType.promptNoun)"
        }
        return shortSubjectDescriptor(for: character)
    }

    private static func shortSubjectDescriptor(for character: AnimationCharacter) -> String {
        "this \(character.genderType.promptNoun)"
    }
}

@available(macOS 26.0, *)
enum CharacterActionPromptCatalog {
    static let defaultAspectRatio = "3:4"
    static let defaultImageSize = "2K"
    static let batchTitle = "Amira Action Images"
    static let batchFolderSlug = "amira-action"

    struct ActionSpec: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let actionInstruction: String
        let environmentHint: String
    }

    static let allSpecs: [ActionSpec] = [
        .init(id: "action_clinic_wounded", title: "Tending Wounded at Clinic", actionInstruction: "kneeling beside a patient on a low cot inside a district clinic, leaning forward to apply a fresh gauze bandage to the patient's forearm, focused serious expression, both hands engaged with the bandage, full upper body and hands clearly visible", environmentHint: "the interior of a plaster-walled Afghan district clinic with a narrow window stripe of daylight, a metal IV pole, pale cotton bedding, and a peeling wall"),
        .init(id: "action_supply_checkpoint", title: "Loading Supplies at Checkpoint", actionInstruction: "lifting a canvas supply crate off the tailgate of a parked pickup, torso twisted, knees slightly bent, weight clearly carried in both arms, full body visible, mid-action gait", environmentHint: "a concrete-barriered checkpoint road with a metal gate and a dusty pickup truck, bright midday sun and a broad desert horizon behind"),
        .init(id: "action_canal_crossing", title: "Crossing Irrigation Canal", actionInstruction: "stepping across a narrow mud-walled irrigation canal on worn wooden planks, one foot mid-step, one hand lightly out for balance, full body clearly visible in three-quarter angle", environmentHint: "a patchwork of green cultivated fields with low mud walls, a clear shallow canal with running water, mountains in the distance, warm late-afternoon light"),
        .init(id: "action_well_pump", title: "Pumping Water at Village Well", actionInstruction: "working a hand pump at a village well, arms mid-stroke, a plastic jerrycan on the ground beside the pump catching water, weight on forward leg, full body visible", environmentHint: "a packed-earth village square with mud-brick homes, a low stone wall, laundry lines, and soft morning light"),
        .init(id: "action_teach_children", title: "Reading With Children on Rooftop", actionInstruction: "sitting cross-legged on a woven mat beside two small children, holding an open notebook, pointing to a page with one finger, warm open expression, full torso and hands visible", environmentHint: "a flat concrete rooftop overlooking the valley town at golden hour, satellite dishes and water tanks nearby, warm amber light across the scene"),
        .init(id: "action_rice_sacks", title: "Carrying Rice Sacks From Truck", actionInstruction: "walking away from an open cargo truck with a heavy burlap rice sack balanced on one shoulder, free hand steadying it, body clearly loaded with weight, full stride, full body visible", environmentHint: "a humanitarian supply depot with stacked pallets under a corrugated metal roof, a dusty open yard, and bright midday sun"),
        .init(id: "action_repair_motorcycle", title: "Repairing Motorcycle in Courtyard", actionInstruction: "crouched beside a battered motorcycle, one knee down, wrench in one hand, other hand steadying the frame, focused intent expression, sleeves pushed up, full body visible at three-quarter angle", environmentHint: "a mechanic's dirt-floor yard with oil drums, cinder blocks, scattered parts, and strong shadow lines from a corrugated roof in afternoon sun"),
        .init(id: "action_radio_guard_post", title: "Radio Check at Guard Post", actionInstruction: "standing inside a sandbag guard post, handheld radio raised to mouth, free hand resting on the sandbags, head slightly tilted listening, alert calm expression, upper two-thirds of body clearly visible", environmentHint: "a plywood-and-sandbag perimeter guard post with open ground behind, clean early-morning light, a dusty unpaved road beyond"),
        .init(id: "action_donkey_cart", title: "Walking Beside Donkey Cart", actionInstruction: "walking alongside a small wooden donkey cart loaded with burlap bundles, one hand loosely on the cart rail, relaxed gait, full body visible in wide frame, believable mid-stride", environmentHint: "a dusty village road between mud-brick homes with hand-painted shop signs, parked bicycles, and bright diffused daylight"),
        .init(id: "action_laundry_courtyard", title: "Hanging Laundry in Courtyard", actionInstruction: "reaching up to peg a damp cloth onto a sagging laundry line, body extended, basket of wet laundry at their feet, calm focused expression, full body visible", environmentHint: "a shaded walled courtyard with packed earth, a single tree, dappled sunlight on the ground, and a wooden bench against the wall"),
    ]

    static func prompt(
        for spec: ActionSpec,
        character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe,
        specIndex: Int = 0
    ) -> String {
        let subject = subjectDescriptor(for: character)
        let shortSubject = shortSubjectDescriptor(for: character)
        let amiraAnchor = CharacterPromptWorldContext.amiraWorldAnchor
        return """
        TASK: Generate a brand-new photorealistic cinematic documentary frame showing \(shortSubject) actively DOING something within the world of Amira. This is NOT a portrait — \(shortSubject) is mid-action, engaged in the labor or care of daily life in this story world. Do NOT reproduce, edit, or copy any reference image. References are provided ONLY for facial identity lock.

        IDENTITY LOCK (from reference images): Retain the facial identity of \(subject) — same face shape, eyes, nose, mouth, hairline, skin tone, and apparent age as shown in the reference images. Do NOT use the references for composition, background, framing, lighting, crop, pose, clothing details, or any other visual element.

        ACTION (this is required — the character must actively be performing this, not posing): \(spec.actionInstruction). Show clear body mechanics, weight distribution, believable mid-action posture, and hands engaged with the task. The framing must make it obvious the subject is WORKING or ACTING, not standing for a portrait.

        WARDROBE: \(wardrobePrompt(for: character, wardrobe: wardrobe))

        SETTING (must be clearly visible and grounded in Amira): Place \(shortSubject) in \(spec.environmentHint). This location exists inside \(amiraAnchor). The environment must feel Amira-specific — humane, lived-in, quiet dramatic realism — not a generic desert warzone, not a Hollywood backlot, not a sanitized stock location.

        RENDERING: natural daylight matched to the environment hint, clean true-to-life color, authentic fabric texture, believable skin and dust detail, sharp subject focus, soft background depth, well-lit and readable.

        NEGATIVE: no static portrait pose, no character just standing looking at camera, no European stone village, no Western movie backlot, no generic desert-warzone stock look, no readable nametag or patch, no gibberish text, no shiny tactical-hero vest, no oversized body armor, no text, no watermark, no dark moody underexposed lighting, no copying of the reference image composition or background.
        """
    }

    private static func wardrobePrompt(
        for character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe
    ) -> String {
        let subject = shortSubjectDescriptor(for: character)
        switch wardrobe {
        case .soldier:
            return "\(subject.capitalized) is wearing \(CharacterPromptWorldContext.militaryClothing), with weathered utility layers, sleeves rolled, subtle local scarf or village-fabric detail, grounded and believable, and no tactical-hero styling."
        case .civilian:
            return "\(subject.capitalized) is wearing \(CharacterPromptWorldContext.civilianClothing), with practical everyday layers, believable local fabrics, and a modest lived-in silhouette."
        }
    }

    private static func subjectDescriptor(for character: AnimationCharacter) -> String {
        if let age = character.age, age > 0 {
            return "this \(age)-year-old \(character.genderType.promptNoun)"
        }
        return shortSubjectDescriptor(for: character)
    }

    private static func shortSubjectDescriptor(for character: AnimationCharacter) -> String {
        "this \(character.genderType.promptNoun)"
    }
}
