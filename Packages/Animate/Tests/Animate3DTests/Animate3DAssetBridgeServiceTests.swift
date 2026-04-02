import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DAssetBridgeServiceTests: XCTestCase {
    func testAssetBridgeReportsMissingPackageForLinkedSceneCharacter() throws {
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

        let adapter = Animate3DSceneAdapter()
        let scenario = adapter.makeScenario(store: store, mode: .selectedScene)
        let snapshot = adapter.frameSnapshot(for: scenario, store: store, rawFrame: 0, playbackStyle: .onTwos)

        let statuses = Animate3DAssetBridgeService().bridgeStatuses(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.readiness, .missing)
        XCTAssertEqual(statuses.first?.assetFolderSlug, "luke")
        XCTAssertEqual(statuses.first?.packageCount, 0)
    }

    func testAssetBridgeReportsReadyForValidWholeCharacterPackage() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let turnaroundSlot = CharacterPoseSlot(
            key: "front-neutral",
            title: "Front Neutral",
            pose: .frontNeutral,
            prompt: "",
            notes: ""
        )
        let masterVariant = CharacterLookDevelopmentVariant(
            imagePath: "Characters/luke/reference-workflow/master.png",
            prompt: "Luke master sheet",
            model: "test"
        )
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: [],
            masterReferenceSheetVariants: [masterVariant],
            approvedMasterReferenceSheetVariantID: masterVariant.id,
            headTurnaroundSlots: [turnaroundSlot]
        )
        let scene = makeScene(characterIDs: [luke.id])
        let store = makeStore(projectURL: projectURL, characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Luke Package",
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
            named: "luke-package",
            in: projectURL,
            files: ["reference.png", "body.png"]
        )

        let adapter = Animate3DSceneAdapter()
        let scenario = adapter.makeScenario(store: store, mode: .selectedScene)
        let snapshot = adapter.frameSnapshot(for: scenario, store: store, rawFrame: 0, playbackStyle: .onTwos)

        let statuses = Animate3DAssetBridgeService().bridgeStatuses(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.readiness, .ready)
        XCTAssertEqual(statuses.first?.activePackageName, "Luke Package")
        XCTAssertEqual(statuses.first?.currentSwapSummary, "Whole-character card swap")
        XCTAssertEqual(statuses.first?.packageCount, 1)
        XCTAssertEqual(statuses.first?.errorCount, 0)
        XCTAssertEqual(statuses.first?.warningCount, 0)
    }

    func testAssetBridgePrefersRigDerivedSwapSummaryWhenPackageLayersResolve() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let turnaroundSlot = CharacterPoseSlot(
            key: "front-neutral",
            title: "Front Neutral",
            pose: .frontNeutral,
            prompt: "",
            notes: ""
        )
        let masterVariant = CharacterLookDevelopmentVariant(
            imagePath: "Characters/luke/reference-workflow/master.png",
            prompt: "Luke master sheet",
            model: "test"
        )
        let manifest = CharacterPackageManifest(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            slug: "luke",
            displayName: "Luke Rig Package",
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
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Rig Head",
                    partType: .head,
                    angle: .front,
                    relativePath: "parts/head.png"
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Rig Torso",
                    partType: .torso,
                    angle: .front,
                    relativePath: "parts/torso.png"
                )
            ]
        )
        let packageRoot = try installPackage(
            manifest,
            for: "luke",
            named: "luke-rig-package",
            in: projectURL,
            files: ["reference.png", "body.png", "parts/head.png", "parts/torso.png"]
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
            ],
            masterReferenceSheetVariants: [masterVariant],
            approvedMasterReferenceSheetVariantID: masterVariant.id,
            headTurnaroundSlots: [turnaroundSlot]
        )
        let scene = makeScene(characterIDs: [luke.id])
        let store = makeStore(projectURL: projectURL, characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let adapter = Animate3DSceneAdapter()
        let scenario = adapter.makeScenario(store: store, mode: .selectedScene)
        let snapshot = adapter.frameSnapshot(for: scenario, store: store, rawFrame: 0, playbackStyle: .onTwos)

        let statuses = Animate3DAssetBridgeService().bridgeStatuses(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.readiness, .ready)
        XCTAssertEqual(statuses.first?.currentSwapSummary, "Rig-derived layered cutout · 2 layers")
    }

    func testAssetBridgeMarksFixtureCastUnavailable() {
        let store = makeStore(projectURL: nil, characters: [], scenes: [], selectedSceneID: nil)
        let adapter = Animate3DSceneAdapter()
        let scenario = adapter.makeScenario(store: store, mode: .fixture)
        let snapshot = adapter.frameSnapshot(for: scenario, store: store, rawFrame: 0, playbackStyle: .onTwos)

        let statuses = Animate3DAssetBridgeService().bridgeStatuses(
            for: scenario,
            snapshot: snapshot,
            store: store
        )

        XCTAssertFalse(statuses.isEmpty)
        XCTAssertTrue(statuses.allSatisfy { $0.readiness == .unavailable })
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
            name: "Bridge Scene",
            backgroundID: nil,
            characterIDs: characterIDs,
            keyframes: [],
            owpSongPath: "Songs/bridge.ows",
            tracks: [:],
            shots: [
                AnimationSceneShot(
                    name: "Opening Wide",
                    startFrame: 0,
                    endFrame: 24,
                    cameraShot: .wide,
                    notes: "Bridge validation.",
                    source: .manual
                )
            ]
        )
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DBridgeTests-\(UUID().uuidString)")
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
