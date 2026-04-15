import Foundation

@available(macOS 26.0, *)
enum PhotorealLORACandidateCatalog {
    enum WardrobeTreatment: Sendable {
        case neutralEveryday
        case groundedStoryWorld
    }

    struct Spec: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var framing: String
        var view: String
        var pose: String
        var expression: String
        var lighting: String
        var environment: String
        var wardrobe: WardrobeTreatment
        var captionTemplate: String
    }

    static let defaultAspectRatio = "3:4"
    static let defaultImageSize = "2K"
    static let batchTitle = "Photoreal LoRA Candidate Batch"
    static let batchFolderSlug = "photoreal-lora-candidates"

    static let allSpecs: [Spec] = identityLockSpecs + controlledRealismSpecs + bodyCoverageSpecs + storyWorldSpecs

    static func prompt(for spec: Spec, character: AnimationCharacter) -> String {
        let subjectPhrase = subjectPhrase(for: character)
        let wardrobeInstruction = wardrobeInstruction(for: spec.wardrobe, character: character)

        return """
        Use the supplied real lifestyle photo references as the only identity anchor for the same exact \(subjectPhrase). Preserve the same face shape, eye area, nose, mouth, jawline, ears, hairline, hair color, hairstyle, skin tone, apparent age, and overall build. Create one single photorealistic image of this exact person. Framing: \(spec.framing). View: \(spec.view). Pose: \(spec.pose). Expression: \(spec.expression). Lighting: \(spec.lighting). Environment: \(spec.environment). Wardrobe: \(wardrobeInstruction). Real-world photography, natural skin texture, realistic pores, believable anatomy, realistic lens rendering, realistic color, sharp focus on the eyes, one person only, face clearly visible, no face obstruction, no hats, no sunglasses, no extra people. No collage, no split panel, no reference sheet, no watermark, no illustration, no CGI, no stylization.
        """
    }

    static func recommendedLORACaption(for spec: Spec) -> String {
        "photo of {trigger} {subject_class}, \(spec.captionTemplate)"
    }

    private static func subjectPhrase(for character: AnimationCharacter) -> String {
        switch character.genderType {
        case .male:
            return "adult man"
        case .female:
            return "adult woman"
        case .person:
            return "adult person"
        }
    }

    private static func wardrobeInstruction(
        for treatment: WardrobeTreatment,
        character: AnimationCharacter
    ) -> String {
        switch treatment {
        case .neutralEveryday:
            return "plain neutral everyday clothing in muted solid colors, simple realistic layers, no logos, no novelty styling"
        case .groundedStoryWorld:
            switch character.defaultWardrobeType {
            case .soldier:
                return "grounded early-2000s military clothing suitable for Afghanistan, muted desert tones, realistic field-ready layers, face fully visible"
            case .civilian:
                return "grounded early-2000s civilian clothing suitable for Afghanistan, modest practical layers, worn natural fabrics, face fully visible"
            }
        }
    }

    private static func spec(
        _ id: String,
        _ title: String,
        framing: String,
        view: String,
        pose: String,
        expression: String,
        lighting: String,
        environment: String,
        wardrobe: WardrobeTreatment,
        caption: String
    ) -> Spec {
        Spec(
            id: id,
            title: title,
            framing: framing,
            view: view,
            pose: pose,
            expression: expression,
            lighting: lighting,
            environment: environment,
            wardrobe: wardrobe,
            captionTemplate: caption
        )
    }

    private static let identityLockSpecs: [Spec] = [
        spec("identity-01", "Studio Front Neutral", framing: "head-and-shoulders portrait", view: "front view looking directly at camera", pose: "upright and still", expression: "neutral", lighting: "soft studio key light with gentle fill", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, front view, studio lighting"),
        spec("identity-02", "Studio Front Serious", framing: "head-and-shoulders portrait", view: "front view looking directly at camera", pose: "upright and still", expression: "serious but calm", lighting: "soft studio key light with gentle fill", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, front view, studio lighting"),
        spec("identity-03", "Studio Front Soft Smile", framing: "head-and-shoulders portrait", view: "front view looking directly at camera", pose: "upright and still", expression: "subtle relaxed smile", lighting: "soft studio key light with gentle fill", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, front view, studio lighting"),
        spec("identity-04", "Three Quarter Left Close", framing: "head-and-shoulders portrait", view: "three-quarter left view", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, three-quarter left view, studio lighting"),
        spec("identity-05", "Three Quarter Right Close", framing: "head-and-shoulders portrait", view: "three-quarter right view", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, three-quarter right view, studio lighting"),
        spec("identity-06", "Left Profile Studio", framing: "head-and-shoulders portrait", view: "true left profile", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, left profile, studio lighting"),
        spec("identity-07", "Right Profile Studio", framing: "head-and-shoulders portrait", view: "true right profile", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, right profile, studio lighting"),
        spec("identity-08", "Close Face Front", framing: "tight face portrait", view: "front view looking directly at camera", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "tight face portrait, front view, studio lighting"),
        spec("identity-09", "Close Face Left", framing: "tight face portrait", view: "three-quarter left view", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "tight face portrait, three-quarter left view, studio lighting"),
        spec("identity-10", "Close Face Right", framing: "tight face portrait", view: "three-quarter right view", pose: "upright and still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "tight face portrait, three-quarter right view, studio lighting"),
        spec("identity-11", "Chest Up Front", framing: "chest-up portrait", view: "front view looking directly at camera", pose: "standing still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "chest-up portrait, front view, studio lighting"),
        spec("identity-12", "Chest Up Left", framing: "chest-up portrait", view: "three-quarter left view", pose: "standing still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "chest-up portrait, three-quarter left view, studio lighting"),
        spec("identity-13", "Chest Up Right", framing: "chest-up portrait", view: "three-quarter right view", pose: "standing still", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "chest-up portrait, three-quarter right view, studio lighting"),
        spec("identity-14", "Seated Waist Up Front", framing: "waist-up portrait", view: "front view", pose: "seated upright in a chair", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, front view, studio lighting"),
        spec("identity-15", "Seated Waist Up Left", framing: "waist-up portrait", view: "three-quarter left view", pose: "seated upright in a chair", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, three-quarter left view, studio lighting"),
        spec("identity-16", "Seated Waist Up Right", framing: "waist-up portrait", view: "three-quarter right view", pose: "seated upright in a chair", expression: "neutral", lighting: "soft studio light", environment: "clean seamless neutral background", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, three-quarter right view, studio lighting"),
        spec("identity-17", "Window Light Front", framing: "head-and-shoulders portrait", view: "front view looking directly at camera", pose: "standing still", expression: "neutral", lighting: "soft natural window light", environment: "simple indoor background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, front view, window light"),
        spec("identity-18", "Open Shade Front", framing: "head-and-shoulders portrait", view: "front view looking directly at camera", pose: "standing still", expression: "neutral", lighting: "soft open shade daylight", environment: "simple outdoor background", wardrobe: .neutralEveryday, caption: "head-and-shoulders portrait, front view, open shade")
    ]

    private static let controlledRealismSpecs: [Spec] = [
        spec("realism-19", "Indoor Window Front", framing: "chest-up portrait", view: "front view", pose: "standing naturally", expression: "neutral", lighting: "indoor window light", environment: "simple lived-in interior", wardrobe: .neutralEveryday, caption: "chest-up portrait, front view, window light"),
        spec("realism-20", "Indoor Window Left", framing: "chest-up portrait", view: "three-quarter left view", pose: "standing naturally", expression: "neutral", lighting: "indoor window light", environment: "simple lived-in interior", wardrobe: .neutralEveryday, caption: "chest-up portrait, three-quarter left view, window light"),
        spec("realism-21", "Indoor Window Right", framing: "chest-up portrait", view: "three-quarter right view", pose: "standing naturally", expression: "neutral", lighting: "indoor window light", environment: "simple lived-in interior", wardrobe: .neutralEveryday, caption: "chest-up portrait, three-quarter right view, window light"),
        spec("realism-22", "Desk Seated Front", framing: "waist-up portrait", view: "front view", pose: "seated at a simple desk", expression: "neutral", lighting: "soft indoor daylight", environment: "quiet interior", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, front view, indoor daylight"),
        spec("realism-23", "Desk Seated Left", framing: "waist-up portrait", view: "three-quarter left view", pose: "seated at a simple desk", expression: "neutral", lighting: "soft indoor daylight", environment: "quiet interior", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, three-quarter left view, indoor daylight"),
        spec("realism-24", "Wall Candid Front", framing: "waist-up portrait", view: "front view", pose: "standing casually against a wall", expression: "neutral", lighting: "soft daylight", environment: "simple textured wall", wardrobe: .neutralEveryday, caption: "waist-up portrait, standing, front view, daylight"),
        spec("realism-25", "Outdoor Shade Front", framing: "chest-up portrait", view: "front view", pose: "standing naturally", expression: "neutral", lighting: "soft open shade daylight", environment: "simple outdoor street background", wardrobe: .neutralEveryday, caption: "chest-up portrait, front view, open shade"),
        spec("realism-26", "Outdoor Shade Left", framing: "chest-up portrait", view: "three-quarter left view", pose: "standing naturally", expression: "neutral", lighting: "soft open shade daylight", environment: "simple outdoor street background", wardrobe: .neutralEveryday, caption: "chest-up portrait, three-quarter left view, open shade"),
        spec("realism-27", "Outdoor Shade Right", framing: "chest-up portrait", view: "three-quarter right view", pose: "standing naturally", expression: "neutral", lighting: "soft open shade daylight", environment: "simple outdoor street background", wardrobe: .neutralEveryday, caption: "chest-up portrait, three-quarter right view, open shade"),
        spec("realism-28", "Walking Toward Camera", framing: "waist-up portrait", view: "front view", pose: "walking slowly toward camera", expression: "neutral", lighting: "soft daylight", environment: "simple outdoor path or street", wardrobe: .neutralEveryday, caption: "waist-up portrait, walking, front view, daylight"),
        spec("realism-29", "Walking Left", framing: "waist-up portrait", view: "three-quarter left view", pose: "walking naturally", expression: "neutral", lighting: "soft daylight", environment: "simple outdoor path or street", wardrobe: .neutralEveryday, caption: "waist-up portrait, walking, three-quarter left view, daylight"),
        spec("realism-30", "Walking Right", framing: "waist-up portrait", view: "three-quarter right view", pose: "walking naturally", expression: "neutral", lighting: "soft daylight", environment: "simple outdoor path or street", wardrobe: .neutralEveryday, caption: "waist-up portrait, walking, three-quarter right view, daylight"),
        spec("realism-31", "Bench Seated Front", framing: "waist-up portrait", view: "front view", pose: "seated on a simple bench", expression: "neutral", lighting: "soft daylight", environment: "simple outdoor setting", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, front view, daylight"),
        spec("realism-32", "Bench Seated Left", framing: "waist-up portrait", view: "three-quarter left view", pose: "seated on a simple bench", expression: "neutral", lighting: "soft daylight", environment: "simple outdoor setting", wardrobe: .neutralEveryday, caption: "waist-up portrait, seated, three-quarter left view, daylight")
    ]

    private static let bodyCoverageSpecs: [Spec] = [
        spec("body-33", "Full Body Front", framing: "full-body portrait", view: "front view", pose: "standing naturally with arms relaxed", expression: "neutral", lighting: "soft studio light", environment: "clean neutral background", wardrobe: .neutralEveryday, caption: "full-body portrait, front view, studio lighting"),
        spec("body-34", "Full Body Left", framing: "full-body portrait", view: "three-quarter left view", pose: "standing naturally with arms relaxed", expression: "neutral", lighting: "soft studio light", environment: "clean neutral background", wardrobe: .neutralEveryday, caption: "full-body portrait, three-quarter left view, studio lighting"),
        spec("body-35", "Full Body Right", framing: "full-body portrait", view: "three-quarter right view", pose: "standing naturally with arms relaxed", expression: "neutral", lighting: "soft studio light", environment: "clean neutral background", wardrobe: .neutralEveryday, caption: "full-body portrait, three-quarter right view, studio lighting"),
        spec("body-36", "Full Body Left Profile", framing: "full-body portrait", view: "true left profile", pose: "standing naturally with arms relaxed", expression: "neutral", lighting: "soft studio light", environment: "clean neutral background", wardrobe: .neutralEveryday, caption: "full-body portrait, left profile, studio lighting"),
        spec("body-37", "Full Body Right Profile", framing: "full-body portrait", view: "true right profile", pose: "standing naturally with arms relaxed", expression: "neutral", lighting: "soft studio light", environment: "clean neutral background", wardrobe: .neutralEveryday, caption: "full-body portrait, right profile, studio lighting"),
        spec("body-38", "Full Body Walking", framing: "full-body portrait", view: "three-quarter front view", pose: "walking naturally", expression: "neutral", lighting: "soft daylight", environment: "simple neutral outdoor setting", wardrobe: .neutralEveryday, caption: "full-body portrait, walking, three-quarter front view, daylight"),
        spec("body-39", "Full Body Seated Chair", framing: "full-body portrait", view: "front view", pose: "seated in a simple chair with feet visible", expression: "neutral", lighting: "soft daylight", environment: "simple indoor setting", wardrobe: .neutralEveryday, caption: "full-body portrait, seated, front view, indoor daylight"),
        spec("body-40", "Full Body Standing Casual", framing: "full-body portrait", view: "front view", pose: "standing naturally with a small relaxed posture shift", expression: "neutral", lighting: "soft daylight", environment: "simple indoor or outdoor neutral setting", wardrobe: .neutralEveryday, caption: "full-body portrait, standing, front view, daylight")
    ]

    private static let storyWorldSpecs: [Spec] = [
        spec("story-41", "Dusty Street Front", framing: "chest-up portrait", view: "front view", pose: "standing naturally", expression: "neutral", lighting: "soft daylight", environment: "a grounded early-2000s Afghanistan street with plaster, concrete, and muted dusty tones", wardrobe: .groundedStoryWorld, caption: "chest-up portrait, front view, outdoors in daylight"),
        spec("story-42", "Clinic Exterior Left", framing: "chest-up portrait", view: "three-quarter left view", pose: "standing naturally", expression: "neutral", lighting: "soft daylight", environment: "outside a modest district clinic with believable documentary realism", wardrobe: .groundedStoryWorld, caption: "chest-up portrait, three-quarter left view, outdoors in daylight"),
        spec("story-43", "Plaster Wall Waist Up", framing: "waist-up portrait", view: "front view", pose: "standing naturally", expression: "neutral", lighting: "soft open shade daylight", environment: "near a simple plaster or mud-brick wall in a grounded documentary setting", wardrobe: .groundedStoryWorld, caption: "waist-up portrait, front view, open shade"),
        spec("story-44", "Doorway Window Light", framing: "waist-up portrait", view: "three-quarter right view", pose: "standing by a doorway", expression: "neutral", lighting: "soft doorway light", environment: "a restrained interior-exterior threshold with realistic materials", wardrobe: .groundedStoryWorld, caption: "waist-up portrait, three-quarter right view, doorway light"),
        spec("story-45", "Clinic Waiting Area", framing: "waist-up portrait", view: "front view", pose: "seated naturally", expression: "neutral", lighting: "soft ambient indoor daylight", environment: "a modest clinic waiting area with grounded documentary realism", wardrobe: .groundedStoryWorld, caption: "waist-up portrait, seated, front view, indoor daylight"),
        spec("story-46", "Street Walk Full Body", framing: "full-body portrait", view: "three-quarter front view", pose: "walking naturally", expression: "neutral", lighting: "soft daylight", environment: CharacterPromptWorldContext.settingSummary, wardrobe: .groundedStoryWorld, caption: "full-body portrait, walking, three-quarter front view, daylight"),
        spec("story-47", "Sunrise Portrait", framing: "chest-up portrait", view: "front view", pose: "standing naturally", expression: "neutral", lighting: "early morning daylight with soft warm tones", environment: "a grounded outdoor setting with restrained documentary realism", wardrobe: .groundedStoryWorld, caption: "chest-up portrait, front view, morning daylight"),
        spec("story-48", "Textured Wall Left", framing: "waist-up portrait", view: "three-quarter left view", pose: "standing naturally", expression: "neutral", lighting: "soft daylight", environment: "against a textured plaster wall with grounded realism", wardrobe: .groundedStoryWorld, caption: "waist-up portrait, three-quarter left view, daylight"),
        spec("story-49", "Checkpoint Visible Face", framing: "waist-up portrait", view: "front view", pose: "standing naturally", expression: "neutral", lighting: "soft daylight", environment: "a restrained checkpoint-adjacent setting with the face large and fully visible", wardrobe: .groundedStoryWorld, caption: "waist-up portrait, front view, outdoors in daylight"),
        spec("story-50", "Outdoor Seated Documentary", framing: "waist-up portrait", view: "three-quarter right view", pose: "seated naturally outdoors", expression: "neutral", lighting: "soft daylight", environment: "a grounded documentary-style outdoor setting with simple real materials", wardrobe: .groundedStoryWorld, caption: "waist-up portrait, seated, three-quarter right view, daylight")
    ]
}
