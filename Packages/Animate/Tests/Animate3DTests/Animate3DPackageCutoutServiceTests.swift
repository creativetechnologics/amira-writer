import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DPackageCutoutServiceTests: XCTestCase {
    func testPackageCutoutServiceBuildsLayeredPartPlan() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = makeScene(characterIDs: [luke.id])
        let store = makeStore(projectURL: projectURL, characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Luke Layers",
            defaults: CharacterPackageDefaults(preferredAngle: .front),
            assets: [
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Head",
                    partType: .head,
                    angle: .front,
                    relativePath: "parts/head.png",
                    tags: ["part-layer"]
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Chest",
                    partType: .chest,
                    angle: .front,
                    relativePath: "parts/chest.png",
                    tags: ["part-layer"]
                )
            ]
        )
        try installPackage(
            manifest,
            for: luke.assetFolderSlug,
            named: "luke-layers",
            in: projectURL,
            files: ["parts/head.png", "parts/chest.png"]
        )

        let scenario = Animate3DSceneAdapter().makeScenario(store: store, mode: .selectedScene)
        let snapshot = Animate3DSceneAdapter().frameSnapshot(
            for: scenario,
            store: store,
            rawFrame: 0,
            playbackStyle: .onTwos
        )

        let plans = Animate3DPackageCutoutService().cutoutPlans(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.mode, .layeredParts)
        XCTAssertTrue(plans.first?.layers.contains(where: { $0.anchor == .head }) == true)
        XCTAssertTrue(plans.first?.layers.contains(where: { $0.anchor == .torso }) == true)
    }

    func testPackageCutoutServicePrefersRigDerivedLayersWhenAvailable() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let manifest = CharacterPackageManifest(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            slug: "luke",
            displayName: "Luke Rig Layers",
            defaults: CharacterPackageDefaults(preferredAngle: .front),
            assets: [
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Rig Head",
                    partType: .head,
                    angle: .front,
                    relativePath: "parts/head.png",
                    tags: ["part-layer"]
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Rig Torso",
                    partType: .torso,
                    angle: .front,
                    relativePath: "parts/torso.png",
                    tags: ["part-layer"]
                )
            ]
        )
        let packageRoot = try installPackage(
            manifest,
            for: "luke",
            named: "luke-rig-layers",
            in: projectURL,
            files: ["parts/head.png", "parts/torso.png"]
        )

        let headVariant = DrawingVariant(
            name: "Rig Head Variant",
            filename: "rig/head.png",
            sourceURL: packageRoot.appendingPathComponent("parts/head.png"),
            sourcePackageID: manifest.id,
            sourcePackageSlug: manifest.slug,
            sourcePackageDisplayName: manifest.displayName,
            sourceAssetRole: .costumeOverlay,
            sourcePartType: .head,
            sourceAngle: .front
        )
        let torsoVariant = DrawingVariant(
            name: "Rig Torso Variant",
            filename: "rig/torso.png",
            sourceURL: packageRoot.appendingPathComponent("parts/torso.png"),
            sourcePackageID: manifest.id,
            sourcePackageSlug: manifest.slug,
            sourcePackageDisplayName: manifest.displayName,
            sourceAssetRole: .costumeOverlay,
            sourcePartType: .torso,
            sourceAngle: .front
        )
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: [
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 10,
                    drawingSets: [
                        .front: DrawingSet(angle: .front, variants: [headVariant])
                    ]
                ),
                RigPart(
                    name: "Torso",
                    partType: .torso,
                    zOrder: 20,
                    drawingSets: [
                        .front: DrawingSet(angle: .front, variants: [torsoVariant])
                    ]
                )
            ]
        )
        let scene = makeScene(characterIDs: [luke.id])
        let store = makeStore(projectURL: projectURL, characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let scenario = Animate3DSceneAdapter().makeScenario(store: store, mode: .selectedScene)
        let snapshot = Animate3DSceneAdapter().frameSnapshot(
            for: scenario,
            store: store,
            rawFrame: 0,
            playbackStyle: .onTwos
        )

        let plans = Animate3DPackageCutoutService().cutoutPlans(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.mode, .rigLayers)
        XCTAssertEqual(plans.first?.layers.count, 2)
        XCTAssertTrue(plans.first?.layers.contains(where: { $0.anchor == .head }) == true)
        XCTAssertTrue(plans.first?.layers.contains(where: { $0.anchor == .torso }) == true)
    }

    func testPackageCutoutServiceBuildsWholeCharacterFallbackPlan() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = makeScene(characterIDs: [luke.id])
        let store = makeStore(projectURL: projectURL, characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Luke Whole",
            defaults: CharacterPackageDefaults(
                preferredAngle: .front,
                preferredPose: .neutral
            ),
            assets: [
                CharacterPackageAsset(
                    role: .reference,
                    name: "Reference",
                    angle: .front,
                    relativePath: "reference.png"
                ),
                CharacterPackageAsset(
                    role: .basePose,
                    name: "Body",
                    angle: .front,
                    pose: .neutral,
                    relativePath: "body.png"
                )
            ]
        )
        try installPackage(
            manifest,
            for: luke.assetFolderSlug,
            named: "luke-whole",
            in: projectURL,
            files: ["reference.png", "body.png"]
        )

        let scenario = Animate3DSceneAdapter().makeScenario(store: store, mode: .selectedScene)
        let snapshot = Animate3DSceneAdapter().frameSnapshot(
            for: scenario,
            store: store,
            rawFrame: 0,
            playbackStyle: .onTwos
        )

        let plans = Animate3DPackageCutoutService().cutoutPlans(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.mode, .wholeCharacter)
        XCTAssertEqual(plans.first?.layers.count, 1)
        XCTAssertEqual(plans.first?.layers.first?.anchor, .root)
    }

    private func makeStore(
        projectURL: URL?,
        characters: [AnimationCharacter],
        scenes: [AnimationScene],
        selectedSceneID: UUID?
    ) -> AnimateStore {
        let store = AnimateStore()
        store.owpURL = projectURL
        store.characters = characters
        store.scenes = scenes
        store.selectedSceneID = selectedSceneID
        return store
    }

    private func makeScene(characterIDs: [UUID]) -> AnimationScene {
        AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Cutout Scene",
            backgroundID: nil,
            characterIDs: characterIDs,
            keyframes: [],
            owpSongPath: "Songs/cutout.ows",
            tracks: [:],
            shots: [
                AnimationSceneShot(
                    name: "Opening Wide",
                    startFrame: 0,
                    endFrame: 24,
                    cameraShot: .wide,
                    notes: "Cutout validation.",
                    source: .manual
                )
            ]
        )
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DCutoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Animate"),
            withIntermediateDirectories: true
        )
        return url
    }

    @discardableResult
    private func installPackage(
        _ manifest: CharacterPackageManifest,
        for characterSlug: String,
        named packageDirectoryName: String,
        in projectURL: URL,
        files: [String]
    ) throws -> URL {
        let packageRoot = projectURL
            .appendingPathComponent("Animate")
            .appendingPathComponent("characters")
            .appendingPathComponent(characterSlug)
            .appendingPathComponent("packages")
            .appendingPathComponent(packageDirectoryName)

        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        let manifestURL = packageRoot.appendingPathComponent("character-package.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL)

        for file in files {
            let fileURL = packageRoot.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
        }

        return packageRoot
    }
}
