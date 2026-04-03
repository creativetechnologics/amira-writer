import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class ScenePreviewRendererTests: XCTestCase {

    /// These tests require real 3D model assets (USDZ/GLB) to be loaded by the renderer.
    /// They are integration tests that validate end-to-end scene rendering with sidecars.
    /// Skip when running without full asset fixtures.
    private static let integrationTestsEnabled: Bool = {
        ProcessInfo.processInfo.environment["ANIMATE_INTEGRATION_TESTS"] == "1"
    }()

    private func skipUnlessIntegrationEnabled() throws {
        try XCTSkipUnless(
            Self.integrationTestsEnabled,
            "ScenePreviewRenderer integration tests require ANIMATE_INTEGRATION_TESTS=1 and 3D model fixtures"
        )
    }

    func testRendererPublishesAuthoredFacialStatusesFromSidecars() async throws {
        try skipUnlessIntegrationEnabled()
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        let animateURL = projectURL.appendingPathComponent("Animate")

        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )

        try writeProfileFragments(at: animateURL, slug: character.assetFolderSlug)
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(
            Animate3DMotionRegistry(
                motions: [
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-determined",
                        title: "Determined Acting",
                        relativePath: "Animate/characters/shared/motions/determined.json",
                        tags: ["determined", "resolve"],
                        notes: ""
                    )
                ]
            ),
            projectURL: projectURL
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.workingOWPURL = projectURL
        store.characters = [character]

        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Facial Status Smoke Test",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/smoke-test.ows"
        )

        let plan = SceneProductionPlan(
            sceneID: scene.id,
            sceneName: scene.name,
            backgroundName: nil,
            totalFrames: 24,
            baseFPS: 24,
            worldChunk: nil,
            styleProfile: nil,
            availableCameraPresetCount: 1,
            lightRig: nil,
            atmospherePreset: nil,
            characterBlocking: [
                CharacterBlockingPlan(
                    characterName: character.name,
                    characterSlug: character.assetFolderSlug,
                    preferredCostumeName: nil,
                    entranceFrame: 0,
                    exitFrame: nil,
                    keyPositions: [
                        BlockingKeyframe(
                            frame: 0,
                            position: SIMD3<Double>(0, 0, 0),
                            facing: .camera,
                            pose: "neutral",
                            emotion: "determined",
                            easing: .linear
                        )
                    ],
                    actingBeats: [
                        ActingBeat(startFrame: 0, endFrame: 12, action: "determined", intensity: 0.8)
                    ],
                    lipsyncBeats: [],
                    holdStyle: .onFours
                )
            ],
            cameraChoreography: CameraChoreographyPlan(
                keyframes: [
                    CameraChoreographyPlan.CameraKeyframe(
                        frame: 0,
                        focalLength: 50,
                        position: SIMD3<Double>(0, 1.5, 8),
                        lookAt: SIMD3<Double>(0, 1.0, -3),
                        roll: 0,
                        movement: .hold,
                        easing: .linear,
                        shotType: .wide,
                        shotIntent: nil,
                        focusCharacter: character.name
                    )
                ]
            ),
            objectPlacements: [],
            depthAssignments: [
                DepthAssignment(elementName: character.name, elementType: .character, depthLayer: "mid", zPosition: -3)
            ],
            frameRateProfile: VariableFrameRateProfile(
                characterHoldStyles: [character.name: .onFours],
                defaultCharacterHold: .onFours,
                cameraHold: .onOnes,
                backgroundHold: .onOnes,
                defaultObjectHold: .onTwos
            )
        )

        let renderer = ScenePreviewRenderer(store: store)
        await renderer.loadPlan(plan)
        renderer.renderFrame(0)

        let status = try XCTUnwrap(renderer.characterPerformanceStatuses.first)
        XCTAssertEqual(status.characterName, character.name)
        XCTAssertEqual(status.profileSourceCount, 3)
        XCTAssertEqual(status.expressionPresetCount, 1)
        XCTAssertEqual(status.visemePresetCount, 1)
        XCTAssertEqual(status.activeExpressionCue, "hero_angry")
        XCTAssertEqual(status.resolvedExpressionPresetCue, "hero_angry")
        XCTAssertEqual(status.expressionCueProvenance, "baseCue:angry")
        XCTAssertTrue(status.usingExpressionPreset)
        XCTAssertEqual(status.activeVisemeCue, "rest")
        XCTAssertEqual(status.resolvedVisemePresetCue, "rest")
        XCTAssertEqual(status.visemeCueProvenance, "baseViseme:rest")
        XCTAssertEqual(status.sourceActionCue, "determined")
        XCTAssertEqual(status.resolvedMotionTitle, "Determined Acting")
        XCTAssertEqual(status.motionProvenance, "tag:determined")
        XCTAssertEqual(status.resolvedHoldMultiplier, 2)
        XCTAssertEqual(status.holdProvenance, "motion:tag:determined:x2")
        XCTAssertTrue(status.usingVisemePreset)
        XCTAssertTrue(status.profileSourcePaths.contains { $0.contains("face-rigs/face-performance.json") })
        XCTAssertTrue(status.profileSourcePaths.contains { $0.contains("mouth-profiles/performance-profile.json") })
        XCTAssertTrue(status.profileSourcePaths.contains { $0.contains("expressions/face-performance.json") })

        let characterNode = try XCTUnwrap(
            renderer.sceneKitScene.rootNode.childNode(withName: "stage", recursively: false)?
                .childNode(withName: "character_\(character.assetFolderSlug)", recursively: true)
        )
        XCTAssertLessThan(characterNode.eulerAngles.x, 0)
    }

    func testRendererSlowsHoldCadenceForListeningMotion() async throws {
        try skipUnlessIntegrationEnabled()
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        let animateURL = projectURL.appendingPathComponent("Animate")

        let character = AnimationCharacter(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Lia",
            description: "Observer",
            owpSlug: "lia",
            parts: []
        )

        try writeProfileFragments(at: animateURL, slug: character.assetFolderSlug)
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(
            Animate3DMotionRegistry(
                motions: [
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-listen",
                        title: "Listening Hold",
                        relativePath: "Animate/characters/shared/motions/listen.json",
                        tags: ["listen", "wait"],
                        notes: ""
                    )
                ]
            ),
            projectURL: projectURL
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.workingOWPURL = projectURL
        store.characters = [character]

        let plan = SceneProductionPlan(
            sceneID: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!,
            sceneName: "Listening Hold Smoke Test",
            backgroundName: nil,
            totalFrames: 24,
            baseFPS: 24,
            worldChunk: nil,
            styleProfile: nil,
            availableCameraPresetCount: 1,
            lightRig: nil,
            atmospherePreset: nil,
            characterBlocking: [
                CharacterBlockingPlan(
                    characterName: character.name,
                    characterSlug: character.assetFolderSlug,
                    preferredCostumeName: nil,
                    entranceFrame: 0,
                    exitFrame: nil,
                    keyPositions: [
                        BlockingKeyframe(
                            frame: 0,
                            position: SIMD3<Double>(0, 0, 0),
                            facing: .camera,
                            pose: "wait",
                            emotion: "neutral",
                            easing: .linear
                        ),
                        BlockingKeyframe(
                            frame: 4,
                            position: SIMD3<Double>(4, 0, 0),
                            facing: .camera,
                            pose: "wait",
                            emotion: "neutral",
                            easing: .linear
                        )
                    ],
                    actingBeats: [
                        ActingBeat(startFrame: 0, endFrame: 12, action: "listen", intensity: 0.4)
                    ],
                    lipsyncBeats: [],
                    holdStyle: .onTwos
                )
            ],
            cameraChoreography: CameraChoreographyPlan(
                keyframes: [
                    CameraChoreographyPlan.CameraKeyframe(
                        frame: 0,
                        focalLength: 50,
                        position: SIMD3<Double>(0, 1.5, 8),
                        lookAt: SIMD3<Double>(0, 1.0, -3),
                        roll: 0,
                        movement: .hold,
                        easing: .linear,
                        shotType: .wide,
                        shotIntent: nil,
                        focusCharacter: character.name
                    )
                ]
            ),
            objectPlacements: [],
            depthAssignments: [
                DepthAssignment(elementName: character.name, elementType: .character, depthLayer: "mid", zPosition: -3)
            ],
            frameRateProfile: VariableFrameRateProfile(
                characterHoldStyles: [character.name: .onTwos],
                defaultCharacterHold: .onTwos,
                cameraHold: .onOnes,
                backgroundHold: .onOnes,
                defaultObjectHold: .onTwos
            )
        )

        let renderer = ScenePreviewRenderer(store: store)
        await renderer.loadPlan(plan)
        renderer.renderFrame(2)

        let status = try XCTUnwrap(renderer.characterPerformanceStatuses.first)
        XCTAssertEqual(status.resolvedMotionID, "motion-listen")
        XCTAssertEqual(status.resolvedHoldMultiplier, 3)
        XCTAssertEqual(status.holdProvenance, "motion:tag:listen:x3")

        let characterNode = try XCTUnwrap(
            renderer.sceneKitScene.rootNode.childNode(withName: "stage", recursively: false)?
                .childNode(withName: "character_\(character.assetFolderSlug)", recursively: true)
        )
        XCTAssertEqual(characterNode.position.x, 0, accuracy: 0.001)
    }

    func testRendererAppliesDescriptorAuthoredMotionOverrides() async throws {
        try skipUnlessIntegrationEnabled()
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        let animateURL = projectURL.appendingPathComponent("Animate")

        let character = AnimationCharacter(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            name: "Mira",
            description: "Lead",
            owpSlug: "mira",
            parts: []
        )

        try writeProfileFragments(at: animateURL, slug: character.assetFolderSlug)
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(
            Animate3DMotionRegistry(
                motions: [
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-custom-hold",
                        title: "Custom Hold",
                        relativePath: "Animate/characters/shared/motions/custom-hold.json",
                        tags: ["focus"],
                        notes: "",
                        preferredHoldMultiplier: 1,
                        bodyPitchOffset: -0.12,
                        bodyRollOffset: 0.08,
                        bodyVerticalOffset: 0.2
                    )
                ]
            ),
            projectURL: projectURL
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.workingOWPURL = projectURL
        store.characters = [character]

        let plan = SceneProductionPlan(
            sceneID: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            sceneName: "Descriptor Motion Override",
            backgroundName: nil,
            totalFrames: 24,
            baseFPS: 24,
            worldChunk: nil,
            styleProfile: nil,
            availableCameraPresetCount: 1,
            lightRig: nil,
            atmospherePreset: nil,
            characterBlocking: [
                CharacterBlockingPlan(
                    characterName: character.name,
                    characterSlug: character.assetFolderSlug,
                    preferredCostumeName: nil,
                    entranceFrame: 0,
                    exitFrame: nil,
                    keyPositions: [
                        BlockingKeyframe(
                            frame: 0,
                            position: SIMD3<Double>(0, 0, 0),
                            facing: .camera,
                            pose: "focus",
                            emotion: "neutral",
                            easing: .linear
                        ),
                        BlockingKeyframe(
                            frame: 4,
                            position: SIMD3<Double>(4, 0, 0),
                            facing: .camera,
                            pose: "focus",
                            emotion: "neutral",
                            easing: .linear
                        )
                    ],
                    actingBeats: [
                        ActingBeat(startFrame: 0, endFrame: 12, action: "focus", intensity: 0.7)
                    ],
                    lipsyncBeats: [],
                    holdStyle: .onFours
                )
            ],
            cameraChoreography: CameraChoreographyPlan(
                keyframes: [
                    CameraChoreographyPlan.CameraKeyframe(
                        frame: 0,
                        focalLength: 50,
                        position: SIMD3<Double>(0, 1.5, 8),
                        lookAt: SIMD3<Double>(0, 1.0, -3),
                        roll: 0,
                        movement: .hold,
                        easing: .linear,
                        shotType: .wide,
                        shotIntent: nil,
                        focusCharacter: character.name
                    )
                ]
            ),
            objectPlacements: [],
            depthAssignments: [
                DepthAssignment(elementName: character.name, elementType: .character, depthLayer: "mid", zPosition: -3)
            ],
            frameRateProfile: VariableFrameRateProfile(
                characterHoldStyles: [character.name: .onFours],
                defaultCharacterHold: .onFours,
                cameraHold: .onOnes,
                backgroundHold: .onOnes,
                defaultObjectHold: .onTwos
            )
        )

        let renderer = ScenePreviewRenderer(store: store)
        await renderer.loadPlan(plan)
        renderer.renderFrame(3)

        let status = try XCTUnwrap(renderer.characterPerformanceStatuses.first)
        XCTAssertEqual(status.resolvedMotionID, "motion-custom-hold")
        XCTAssertEqual(status.resolvedHoldMultiplier, 1)
        XCTAssertEqual(status.holdProvenance, "descriptor:hold:x1")
        XCTAssertEqual(status.motionHintSummary, "hold x1 • pitch -0.12 • roll 0.08 • y 0.20")

        let characterNode = try XCTUnwrap(
            renderer.sceneKitScene.rootNode.childNode(withName: "stage", recursively: false)?
                .childNode(withName: "character_\(character.assetFolderSlug)", recursively: true)
        )
        XCTAssertEqual(characterNode.position.x, 3, accuracy: 0.001)
        XCTAssertEqual(characterNode.position.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(characterNode.eulerAngles.x, -0.19, accuracy: 0.001)
        XCTAssertEqual(characterNode.eulerAngles.z, 0.08, accuracy: 0.001)
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenePreviewRendererTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeProfileFragments(at animateURL: URL, slug: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let faceRigProfile = Character3DPerformanceProfile(
            headNodeName: "head",
            faceNodeName: "face",
            jawNodeName: "jaw",
            mouthNodeName: "mouth",
            leftEyeNodeName: "eye_l",
            rightEyeNodeName: "eye_r",
            leftBrowNodeName: "brow_l",
            rightBrowNodeName: "brow_r"
        )
        let mouthProfile = Character3DPerformanceProfile(
            mouthProfileID: "lipsync-default",
            visemePresets: [
                "rest": CharacterPerformanceMouthPreset(
                    jawOpen: 0.02,
                    mouthWidth: 0.42,
                    mouthHeight: 0.08,
                    pucker: 0,
                    smileBlend: 0
                )
            ]
        )
        let expressionProfile = Character3DPerformanceProfile(
            expressionPresets: [
                "hero_angry": CharacterPerformanceExpressionPreset(
                    browLift: -0.22,
                    browTilt: -0.25,
                    eyeOpen: 0.82,
                    smile: -0.08,
                    headPitch: -0.03
                )
            ]
        )

        try writeProfile(faceRigProfile, encoder: encoder, to: animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("face-rigs")
            .appendingPathComponent("face-performance.json"))

        try writeProfile(mouthProfile, encoder: encoder, to: animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("mouth-profiles")
            .appendingPathComponent("performance-profile.json"))

        try writeProfile(expressionProfile, encoder: encoder, to: animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("expressions")
            .appendingPathComponent("face-performance.json"))
    }

    private func writeProfile(
        _ profile: Character3DPerformanceProfile,
        encoder: JSONEncoder,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }
}
