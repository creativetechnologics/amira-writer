import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DGenerationQueuePlannerTests: XCTestCase {
    func testPlannerSkipsCharacterDeliverablesSatisfiedByRegistryBundle() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let bodyPath = "Animate/3d/generated-assets/luke/default/luke.glb"
        let facePath = "Animate/3d/generated-assets/luke/default/face.json"
        let mouthPath = "Animate/3d/generated-assets/luke/default/mouth.json"
        let expressionPath = "Animate/3d/generated-assets/luke/default/expressions.json"
        let motionPath = "Animate/3d/generated-assets/luke/default/motions/idle.json"
        let materialPath = "Animate/3d/generated-assets/luke/default/lookdev.json"
        try createDataFile(Data(), at: projectURL.appendingPathComponent(bodyPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(facePath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(mouthPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(expressionPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(motionPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent(materialPath))

        let characterRegistry = Animate3DCharacterRegistry(
            bundles: [
                Animate3DCharacterBundleDescriptor(
                    characterSlug: "luke",
                    costumeName: "default",
                    bodyModelPath: bodyPath,
                    faceRigPath: facePath,
                    mouthProfilePath: mouthPath,
                    expressionLibraryPath: expressionPath,
                    motionSetPaths: [motionPath],
                    materialProfilePath: materialPath
                )
            ]
        )
        try ProjectDatabaseBridge.saveAnimate3DCharacterRegistryToDisk(characterRegistry, projectURL: projectURL)

        let store = AnimateStore()
        store.owpURL = projectURL
        store.characters = [
            AnimationCharacter(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "Luke",
                description: "Pilot",
                owpSlug: "luke",
                parts: []
            )
        ]

        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [store.characters[0].id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        let items = Animate3DGenerationQueuePlanner(store: store)
            .plan(scene: scene, productionPlan: sampleProductionPlan(scene: scene))
            .items

        XCTAssertFalse(items.contains(where: { $0.kind == .bodyModel }))
        XCTAssertFalse(items.contains(where: { $0.kind == .faceRig }))
        XCTAssertFalse(items.contains(where: { $0.kind == .mouthProfile }))
        XCTAssertFalse(items.contains(where: { $0.kind == .expressionLibrary }))
        XCTAssertFalse(items.contains(where: { $0.kind == .motionSet }))
        XCTAssertFalse(items.contains(where: { $0.kind == .materialProfile }))
    }

    func testPlannerUsesRuntimeMotionCuesInMissingMotionPrompt() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let store = AnimateStore()
        store.owpURL = projectURL
        store.characters = [
            AnimationCharacter(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "Luke",
                description: "Pilot",
                owpSlug: "luke",
                parts: []
            )
        ]

        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [store.characters[0].id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        let runtimeStatus = Animate3DCharacterPerformanceStatus(
            characterName: "Luke",
            characterSlug: "luke",
            preferredCostumeName: nil,
            resolvedBundleCostumeName: nil,
            resolvedBundleSourcePath: nil,
            resolvedBundleAssetPaths: [],
            modelFileName: nil,
            modelSourcePath: nil,
            driverMode: .generatedOverlay,
            profileSourceFileName: nil,
            profileSourcePath: nil,
            profileSourceCount: 0,
            profileSourcePaths: [],
            mouthProfileID: nil,
            expressionPresetCount: 0,
            visemePresetCount: 0,
            usingExpressionPreset: false,
            usingVisemePreset: false,
            resolvedExpressionPresetCue: nil,
            resolvedVisemePresetCue: nil,
            sourceExpressionCue: "neutral",
            sourceVisemeCue: "rest",
            expressionBehaviorCue: nil,
            expressionCueProvenance: nil,
            visemeCueProvenance: nil,
            sourceActionCue: "determined",
            sourcePoseCue: "listen",
            resolvedMotionID: "motion-determined-listen",
            resolvedMotionTitle: "Determined Listening",
            motionProvenance: "semantic:determined+listen",
            resolvedHoldMultiplier: 2,
            holdProvenance: "motion:semantic:determined+listen:x2",
            motionHintSummary: nil,
            activeExpressionCue: "neutral",
            activeVisemeCue: "rest",
            isVisible: true
        )

        let items = Animate3DGenerationQueuePlanner(store: store)
            .buildPlan(
                scene: scene,
                backgroundName: "Moon Valley",
                worldChunk: nil,
                styleProfile: nil,
                lightRig: nil,
                atmospherePreset: nil,
                bundleReadiness: [
                    Animate3DCharacterBundleReadinessStatus(
                        characterName: "Luke",
                        characterSlug: "luke",
                        preferredCostumeName: nil,
                        resolvedBundleCostumeName: nil,
                        resolvedBundleSourcePath: nil,
                        resolvedBundleAssetPaths: [],
                        readyCategories: [],
                        registryBackedCategories: [],
                        missingCategories: [.motions],
                        totalFileCount: 0
                    )
                ],
                runtimeCharacters: [runtimeStatus]
            )

        let motionItem = try XCTUnwrap(items.first(where: { $0.kind == .motionSet }))
        XCTAssertTrue(motionItem.detail.contains("determined"))
        XCTAssertTrue(motionItem.detail.contains("listen"))
        XCTAssertTrue(motionItem.prompt.contains("Determined Listening"))
    }

    private func sampleProductionPlan(scene: AnimationScene) -> SceneProductionPlan {
        SceneProductionPlan(
            sceneID: scene.id,
            sceneName: scene.name,
            backgroundName: "Moon Valley",
            totalFrames: 0,
            baseFPS: 24,
            worldChunk: Animate3DWorldChunkDescriptor(
                worldID: "amira",
                zoneID: "moon-valley",
                title: "Moon Valley",
                placeNames: ["Moon Valley"],
                meshPath: "Animate/3d/world-catalog/moon-valley.glb",
                depthMapPath: nil,
                previewImagePath: "Animate/3d/world-catalog/moon-valley.png",
                styleProfileID: "amira-default",
                atmospherePresetID: "default-atmo",
                lightRigID: "default-rig"
            ),
            styleProfile: Animate3DStyleProfileDescriptor(
                profileID: "amira-default",
                title: "Amira Default",
                notes: "",
                celBands: 3,
                outlineWidth: 1
            ),
            availableCameraPresetCount: 1,
            lightRig: Animate3DLightRigDescriptor(
                rigID: "default-rig",
                title: "Default Rig",
                keyIntensity: 1,
                fillIntensity: 1,
                rimIntensity: 1,
                notes: ""
            ),
            atmospherePreset: Animate3DAtmospherePresetDescriptor(
                presetID: "default-atmo",
                title: "Default Atmosphere",
                fogDensity: 0,
                haze: 0,
                colorHex: "#FFFFFF",
                notes: ""
            ),
            characterBlocking: [],
            cameraChoreography: CameraChoreographyPlan(keyframes: []),
            objectPlacements: [],
            depthAssignments: [],
            frameRateProfile: VariableFrameRateProfile(
                characterHoldStyles: [:],
                defaultCharacterHold: .onTwos,
                cameraHold: .onOnes,
                backgroundHold: .onThrees,
                defaultObjectHold: .onTwos
            )
        )
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DGenerationQueuePlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDataFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
