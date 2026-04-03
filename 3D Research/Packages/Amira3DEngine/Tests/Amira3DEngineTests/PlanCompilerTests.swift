import Testing
@testable import Amira3DEngine

struct PlanCompilerTests {
    @Test
    func previewMapsCommandFamiliesIntoEffectScopes() {
        let plan = ScenePlan(
            sceneID: "scene.valley.intro",
            commands: [
                SceneCommand(
                    id: "cmd.world.1",
                    family: .world,
                    target: "world.valley.main",
                    action: "activate",
                    parameters: ["variant": .string("default_establishing")]
                ),
                SceneCommand(
                    id: "cmd.face.1",
                    family: .face,
                    target: "character.luke",
                    action: "activate",
                    parameters: [
                        "faceRigId": .string("face_rig.luke.01"),
                        "expressionProfileId": .string("expr_profile.luke.01")
                    ]
                ),
                SceneCommand(
                    id: "cmd.expression.1",
                    family: .expression,
                    target: "character.luke",
                    action: "update",
                    parameters: [
                        "expressionProfileId": .string("expr_profile.luke.01"),
                        "expressionId": .string("neutral"),
                        "intensity": .number(0.8)
                    ]
                ),
                SceneCommand(
                    id: "cmd.light.1",
                    family: .light,
                    target: "sunrise_soft_directional",
                    action: "activate"
                )
            ]
        )

        let preview = PlanCompiler().preview(plan: plan)

        #expect(preview.effects.count == 4)
        #expect(preview.effects[0].scope == .worldState)
        #expect(preview.effects[1].scope == .faceState)
        #expect(preview.effects[2].scope == .expressionState)
        #expect(preview.effects[3].scope == .lightRig)
    }

    @Test
    func runtimeStagesAndAppliesPreview() async {
        let runtime = Amira3DRuntimeShell()
        let plan = ScenePlan(
            sceneID: "scene.valley.intro",
            commands: [
                SceneCommand(
                    id: "cmd.asset.1",
                    family: .asset,
                    target: "bridge_main",
                    action: "place",
                    parameters: [
                        "translation": .object([
                            "x": .number(1),
                            "y": .number(2),
                            "z": .number(3)
                        ])
                    ]
                ),
                SceneCommand(
                    id: "cmd.mouth.1",
                    family: .mouth,
                    target: "character.luke",
                    action: "activate",
                    parameters: [
                        "mouthProfileId": .string("mouth_profile.luke.01"),
                        "viseme": .string("rest")
                    ]
                )
            ]
        )

        let preview = await runtime.stage(plan)
        await runtime.apply(preview)
        let state = await runtime.state

        #expect(state.sceneID == "scene.valley.intro")
        #expect(state.world.assetPlacements[AssetID("bridge_main")]?.translation.x == 1)
        #expect(state.characters[CharacterID("character.luke")]?.face.mouthProfileID == MouthProfileID("mouth_profile.luke.01"))
    }
}
