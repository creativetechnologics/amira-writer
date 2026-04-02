import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DProductionCoordinatorTests: XCTestCase {
    func testRefreshReloadsWhenCharacterRegistryChanges() async throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.characters = [character]
        store.scenes = [scene]

        let coordinator = Animate3DProductionCoordinator(store: store)
        await coordinator.refresh(
            scene: scene,
            lyrics: "",
            scenario: .empty,
            forceReload: true
        )
        XCTAssertEqual(coordinator.status.modelBackedCharacterCount, 0)

        let bodyPath = "Animate/3d/generated-assets/luke/default/luke.glb"
        try createDataFile(Data(), at: projectURL.appendingPathComponent(bodyPath))
        try ProjectDatabaseBridge.saveAnimate3DCharacterRegistryToDisk(
            Animate3DCharacterRegistry(
                bundles: [
                    Animate3DCharacterBundleDescriptor(
                        characterSlug: "luke",
                        costumeName: "default",
                        bodyModelPath: bodyPath
                    )
                ]
            ),
            projectURL: projectURL
        )

        await coordinator.refresh(
            scene: scene,
            lyrics: "",
            scenario: .empty,
            forceReload: false
        )
        XCTAssertEqual(coordinator.status.modelBackedCharacterCount, 1)
        let readiness = try XCTUnwrap(coordinator.status.bundleReadiness.first)
        XCTAssertEqual(readiness.resolvedBundleSourcePath, "Animate/3d/character-registry/character-registry.json")
        XCTAssertTrue(readiness.resolvedBundleAssetPaths.contains(bodyPath))
        let runtimeStatus = try XCTUnwrap(coordinator.status.runtimeCharacters.first)
        XCTAssertEqual(runtimeStatus.modelSourcePath, bodyPath)
    }

    func testRefreshPublishesFacialProvenanceFromSidecars() async throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        try writeProfileFragments(
            at: projectURL.appendingPathComponent("Animate"),
            slug: character.assetFolderSlug
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.workingOWPURL = projectURL
        store.characters = [character]
        store.scenes = [scene]

        let coordinator = Animate3DProductionCoordinator(store: store)
        await coordinator.refresh(
            scene: scene,
            lyrics: "",
            scenario: .empty,
            forceReload: true
        )

        let runtimeStatus = try XCTUnwrap(coordinator.status.runtimeCharacters.first)
        XCTAssertEqual(runtimeStatus.characterName, character.name)
        XCTAssertEqual(runtimeStatus.sourceExpressionCue, "neutral")
        XCTAssertEqual(runtimeStatus.expressionBehaviorCue, "neutral")
        XCTAssertEqual(runtimeStatus.activeExpressionCue, "hero_neutral")
        XCTAssertEqual(runtimeStatus.expressionCueProvenance, "baseCue:neutral")
        XCTAssertEqual(runtimeStatus.sourceVisemeCue, "rest")
        XCTAssertEqual(runtimeStatus.activeVisemeCue, "hero_rest")
        XCTAssertEqual(runtimeStatus.visemeCueProvenance, "baseViseme:rest")
    }

    func testRefreshPublishesMotionProvenanceFromRegistry() async throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Luke Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/luke.ows"
        )

        try writeProfileFragments(
            at: projectURL.appendingPathComponent("Animate"),
            slug: character.assetFolderSlug
        )
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
        store.scenes = [scene]

        let coordinator = Animate3DProductionCoordinator(store: store)
        let lyrics = """
        [scene: "Luke Scene" | bg=Debug Stage]
        [action: "Luke" | determined | bars=1]
        """
        await coordinator.refresh(
            scene: scene,
            lyrics: lyrics,
            scenario: .empty,
            forceReload: true
        )

        let runtimeStatus = try XCTUnwrap(coordinator.status.runtimeCharacters.first)
        XCTAssertEqual(runtimeStatus.sourceActionCue, "determined")
        XCTAssertEqual(runtimeStatus.resolvedMotionID, "motion-determined")
        XCTAssertEqual(runtimeStatus.resolvedMotionTitle, "Determined Acting")
        XCTAssertEqual(runtimeStatus.motionProvenance, "tag:determined")
        XCTAssertEqual(runtimeStatus.resolvedHoldMultiplier, 2)
        XCTAssertEqual(runtimeStatus.holdProvenance, "motion:tag:determined:x2")
    }

    func testRefreshPublishesDescriptorHoldOverrideFromRegistry() async throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let character = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111")!,
            name: "Luke",
            description: "Pilot",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-BBBBBBBBBBBB")!,
            name: "Descriptor Hold Scene",
            backgroundID: nil,
            characterIDs: [character.id],
            keyframes: [],
            owpSongPath: "Songs/test.ows"
        )

        try writeProfileFragments(
            at: projectURL.appendingPathComponent("Animate"),
            slug: character.assetFolderSlug
        )
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(
            Animate3DMotionRegistry(
                motions: [
                    Animate3DMotionSetDescriptor(
                        motionID: "motion-focus-close",
                        title: "Focus Close Hold",
                        relativePath: "Animate/characters/shared/motions/focus-close.json",
                        tags: ["focus"],
                        notes: "",
                        preferredHoldMultiplier: 1
                    )
                ]
            ),
            projectURL: projectURL
        )

        let store = AnimateStore()
        store.owpURL = projectURL
        store.workingOWPURL = projectURL
        store.characters = [character]
        store.scenes = [scene]

        let coordinator = Animate3DProductionCoordinator(store: store)
        let lyrics = """
        [scene: "Luke Scene" | bg=Debug Stage]
        [action: "Luke" | focus | bars=1]
        """
        await coordinator.refresh(
            scene: scene,
            lyrics: lyrics,
            scenario: .empty,
            forceReload: true
        )

        let runtimeStatus = try XCTUnwrap(coordinator.status.runtimeCharacters.first)
        XCTAssertEqual(runtimeStatus.resolvedMotionID, "motion-focus-close")
        XCTAssertEqual(runtimeStatus.resolvedHoldMultiplier, 1)
        XCTAssertEqual(runtimeStatus.holdProvenance, "descriptor:hold:x1")
        XCTAssertEqual(runtimeStatus.motionHintSummary, "hold x1")
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DProductionCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDataFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
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
                "hero_rest": CharacterPerformanceMouthPreset(
                    aliases: [],
                    baseVisemeToken: "rest",
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
                "hero_neutral": CharacterPerformanceExpressionPreset(
                    aliases: [],
                    baseCue: "neutral",
                    browLift: 0,
                    browTilt: 0,
                    eyeOpen: 1,
                    smile: 0,
                    headPitch: 0
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
