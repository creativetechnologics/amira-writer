import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class SceneAssetPipelineRegistryTests: XCTestCase {
    func testCharacterRegistryProvidesModelFileNameAndPerformanceProfile() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let profile = Character3DPerformanceProfile(
            headNodeName: "Head",
            faceNodeName: "Face",
            jawNodeName: "Jaw",
            mouthNodeName: "Mouth",
            leftEyeNodeName: "Eye_L",
            rightEyeNodeName: "Eye_R",
            leftBrowNodeName: "Brow_L",
            rightBrowNodeName: "Brow_R",
            mouthProfileID: "default-mouth"
        )

        let faceRigPath = "Animate/characters/luke/face-rigs/performance-profile.json"
        try createJSONFile(profile, at: projectURL.appendingPathComponent(faceRigPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent("Animate/characters/luke/models/luke.glb"))

        let characterRegistry = Animate3DCharacterRegistry(
            bundles: [
                Animate3DCharacterBundleDescriptor(
                    characterSlug: "luke",
                    costumeName: "default",
                    bodyModelPath: "Animate/characters/luke/models/luke.glb",
                    faceRigPath: faceRigPath,
                    mouthProfilePath: nil,
                    expressionLibraryPath: nil,
                    motionSetPaths: ["Animate/characters/luke/motions/idle.json"],
                    materialProfilePath: "Animate/characters/luke/materials/lookdev.json"
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

        let pipeline = SceneAssetPipeline(store: store)

        XCTAssertEqual(pipeline.characterModelFileName(slug: "luke"), "luke.glb")
        XCTAssertEqual(pipeline.characterPerformanceProfileSourceRelativePath(slug: "luke"), faceRigPath)
        XCTAssertEqual(pipeline.loadCharacterPerformanceProfile(slug: "luke"), profile)
    }

    func testRegistryBackedFaceMouthAndExpressionProfilesMerge() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let faceRigPath = "Animate/3d/generated-assets/luke/default/face.json"
        let mouthProfilePath = "Animate/3d/generated-assets/luke/default/mouth.json"
        let expressionLibraryPath = "Animate/3d/generated-assets/luke/default/expressions.json"

        let faceRigProfile = Character3DPerformanceProfile(
            headNodeName: "Head",
            faceNodeName: "Face",
            jawNodeName: "Jaw",
            mouthNodeName: nil,
            leftEyeNodeName: nil,
            rightEyeNodeName: nil,
            leftBrowNodeName: nil,
            rightBrowNodeName: nil,
            mouthProfileID: "luke-mouth"
        )
        let mouthProfile = Character3DPerformanceProfile(
            visemePresets: [
                "ai": CharacterPerformanceMouthPreset(
                    jawOpen: 0.7,
                    mouthWidth: 0.6,
                    mouthHeight: 0.8,
                    pucker: 0.1,
                    smileBlend: 0.2
                )
            ]
        )
        let expressionLibrary = Character3DPerformanceProfile(
            expressionPresets: [
                "joy": CharacterPerformanceExpressionPreset(
                    browLift: 0.3,
                    browTilt: -0.05,
                    eyeOpen: 0.9,
                    smile: 0.7,
                    headPitch: -0.02
                )
            ]
        )

        try createJSONFile(faceRigProfile, at: projectURL.appendingPathComponent(faceRigPath))
        try createJSONFile(mouthProfile, at: projectURL.appendingPathComponent(mouthProfilePath))
        try createJSONFile(expressionLibrary, at: projectURL.appendingPathComponent(expressionLibraryPath))
        try createDataFile(Data(), at: projectURL.appendingPathComponent("Animate/3d/generated-assets/luke/default/luke.glb"))

        let characterRegistry = Animate3DCharacterRegistry(
            bundles: [
                Animate3DCharacterBundleDescriptor(
                    characterSlug: "luke",
                    costumeName: "default",
                    bodyModelPath: "Animate/3d/generated-assets/luke/default/luke.glb",
                    faceRigPath: faceRigPath,
                    mouthProfilePath: mouthProfilePath,
                    expressionLibraryPath: expressionLibraryPath,
                    motionSetPaths: [],
                    materialProfilePath: nil
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

        let pipeline = SceneAssetPipeline(store: store)
        let merged = try XCTUnwrap(pipeline.loadCharacterPerformanceProfile(slug: "luke"))
        let sourcePath = try XCTUnwrap(pipeline.characterPerformanceProfileSourceRelativePath(slug: "luke"))

        XCTAssertEqual(merged.headNodeName, "Head")
        XCTAssertEqual(merged.mouthProfileID, "luke-mouth")
        XCTAssertNotNil(merged.visemePresets["ai"])
        XCTAssertNotNil(merged.expressionPresets["joy"])
        XCTAssertTrue(sourcePath.contains(faceRigPath))
        XCTAssertTrue(sourcePath.contains(mouthProfilePath))
        XCTAssertTrue(sourcePath.contains(expressionLibraryPath))
    }

    func testResolveMotionSetPrefersHighestOverlapAcrossActionAndPose() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(
            Animate3DMotionRegistry(
                motions: [
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-determined",
                        title: "Determined Acting",
                        relativePath: "Animate/characters/shared/motions/determined.json",
                        tags: ["determined"],
                        notes: ""
                    ),
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-listen",
                        title: "Listening Hold",
                        relativePath: "Animate/characters/shared/motions/listen.json",
                        tags: ["listen"],
                        notes: ""
                    ),
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-determined-listen",
                        title: "Determined Listening",
                        relativePath: "Animate/characters/shared/motions/determined-listen.json",
                        tags: ["determined", "listen"],
                        notes: "Stoic attentive acting."
                    )
                ]
            ),
            projectURL: projectURL
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        let pipeline = SceneAssetPipeline(store: store)
        let resolved = try XCTUnwrap(
            pipeline.resolveMotionSet(actionCue: "determined", poseCue: "listen")
        )

        XCTAssertEqual(resolved.descriptor.motionID, "motion-determined-listen")
        XCTAssertEqual(resolved.provenance, "tag:determined")
    }

    func testResolveMotionSetFallsBackToSemanticNotesAndPathTokens() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(
            Animate3DMotionRegistry(
                motions: [
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-kneel-prayer",
                        title: "Solemn Hold",
                        relativePath: "Animate/characters/shared/motions/kneel-prayer.json",
                        tags: [],
                        notes: "Kneeling prayer beat for solemn pleading."
                    )
                ]
            ),
            projectURL: projectURL
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        let pipeline = SceneAssetPipeline(store: store)
        let resolved = try XCTUnwrap(
            pipeline.resolveMotionSet(actionCue: "solemn prayer", poseCue: "kneel")
        )

        XCTAssertEqual(resolved.descriptor.motionID, "motion-kneel-prayer")
        XCTAssertEqual(resolved.provenance, "semantic:kneel+prayer+solemn")
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAssetPipelineRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createJSONFile<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    private func createDataFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
