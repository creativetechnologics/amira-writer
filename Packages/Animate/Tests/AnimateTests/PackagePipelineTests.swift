import Foundation
import XCTest
import ProjectKit
@testable import AnimateUI

@available(macOS 26.0, *)
final class PackagePipelineTests: XCTestCase {
    func testValidatorRejectsUnsafePathsAndBrokenBlueprintReferences() {
        let safeAssetID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let unsafeAssetID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let missingReferenceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        let manifest = CharacterPackageManifest(
            slug: "Luke",
            displayName: "Luke Package",
            assets: [
                CharacterPackageAsset(
                    id: safeAssetID,
                    role: .reference,
                    name: "Reference",
                    relativePath: "references/luke.png"
                ),
                CharacterPackageAsset(
                    id: unsafeAssetID,
                    role: .basePose,
                    name: "Unsafe",
                    relativePath: "../escape.png"
                )
            ],
            blueprints: [
                CharacterGenerationBlueprint(
                    name: "Broken Blueprint",
                    prompt: " ",
                    referenceAssetIDs: [missingReferenceID],
                    outputSpecs: [
                        CharacterPackageOutputSpec(role: .basePose, count: 0)
                    ]
                )
            ]
        )

        let report = CharacterPackageValidator().validate(manifest)
        let codes = Set(report.issues.map(\.code))

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(codes.contains(.invalidRelativePath))
        XCTAssertTrue(codes.contains(.emptyBlueprintPrompt))
        XCTAssertTrue(codes.contains(.missingBlueprintReference))
        XCTAssertTrue(codes.contains(.invalidOutputCount))
    }

    func testValidatorAllowsReasonablePlacementOverhang() {
        let manifest = CharacterPackageManifest(
            slug: "Luke",
            displayName: "Luke Placement",
            assets: [
                CharacterPackageAsset(
                    role: .reference,
                    name: "Reference",
                    relativePath: "references/luke.png"
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Foot Layer",
                    partType: .footLeft,
                    placement: CharacterPackageAssetPlacement(
                        normalizedCenter: CharacterPackageNormalizedPoint(x: 0.42, y: 1.03),
                        normalizedSize: CharacterPackageNormalizedSize(width: 0.18, height: 0.10)
                    ),
                    relativePath: "parts/foot-left.png"
                )
            ]
        )

        let report = CharacterPackageValidator().validate(manifest)
        let codes = Set(report.issues.map(\.code))

        XCTAssertFalse(codes.contains(.invalidPlacementCenter))
        XCTAssertFalse(codes.contains(.invalidPlacementSize))
    }

    func testValidatorRejectsOutOfRangePlacementPivotAndZOrder() {
        let manifest = CharacterPackageManifest(
            slug: "Luke",
            displayName: "Luke Placement",
            assets: [
                CharacterPackageAsset(
                    role: .reference,
                    name: "Reference",
                    relativePath: "references/luke.png"
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Head Layer",
                    partType: .head,
                    placement: CharacterPackageAssetPlacement(
                        normalizedPivot: CharacterPackageNormalizedPoint(x: 2.0, y: 0.5),
                        zOrderOverride: 5001
                    ),
                    relativePath: "parts/head.png"
                )
            ]
        )

        let report = CharacterPackageValidator().validate(manifest)
        let codes = Set(report.issues.map(\.code))

        XCTAssertTrue(codes.contains(.invalidPlacementPivot))
        XCTAssertTrue(codes.contains(.invalidPlacementZOrderOverride))
    }

    func testImportServiceCopiesAssetsAndWritesManifestUsingTargetSlug() throws {
        let packageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let manifest = CharacterPackageManifest(
            id: packageID,
            slug: "Luke Painterly",
            displayName: "Luke Painterly",
            assets: [
                CharacterPackageAsset(
                    role: .basePose,
                    name: "Base",
                    angle: .front,
                    pose: .frontal,
                    relativePath: "poses/base.png",
                    tags: ["default", "render"]
                )
            ]
        )

        let packageURL = try makePackageDirectory(manifest: manifest)
        let animateURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: animateURL)
        }

        let service = CharacterPackageImportService()
        let plan = try service.makeImportPlan(
            from: packageURL,
            into: animateURL,
            targetCharacterSlug: "Luke Hero"
        )

        XCTAssertEqual(plan.targetCharacterSlug, "luke-hero")
        XCTAssertTrue(plan.stagingDirectoryURL.path.contains("/characters/luke-hero/packages/\(packageID.uuidString)"))
        XCTAssertEqual(plan.copyOperations.count, 1)

        try service.execute(plan)

        let copiedAssetURL = plan.stagingDirectoryURL.appendingPathComponent("poses/base.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedAssetURL.path))

        let writtenManifestURL = plan.stagingDirectoryURL.appendingPathComponent("character-package.json")
        let manifestData = try Data(contentsOf: writtenManifestURL)
        let writtenManifest = try JSONCoders.makeDecoder().decode(CharacterPackageManifest.self, from: manifestData)
        XCTAssertEqual(writtenManifest.slug, "luke-hero")
        XCTAssertEqual(writtenManifest.id, packageID)
    }

    func testLibraryOrdersPackagesNewestFirst() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let olderID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let newerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let olderDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: olderID,
                slug: "luke",
                displayName: "Older",
                assets: [makeBasePoseAsset(path: "poses/older.png")]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )
        let newerDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: newerID,
                slug: "luke",
                displayName: "Newer",
                assets: [makeBasePoseAsset(path: "poses/newer.png")]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: olderDirectory.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newerDirectory.path
        )

        let packages = CharacterPackageLibrary().installedPackages(for: "luke", in: animateURL)

        XCTAssertEqual(packages.map(\.manifest.id), [newerID, olderID])
        XCTAssertEqual(CharacterPackageLibrary().primaryAsset(for: packages[0])?.role, .basePose)
    }

    func testLibraryHonorsPersistedActivePackageSelection() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let olderID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let newerID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let olderDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: olderID,
                slug: "luke",
                displayName: "Older Active",
                assets: [makeBasePoseAsset(path: "poses/older.png")]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )
        let newerDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: newerID,
                slug: "luke",
                displayName: "Newer Default",
                assets: [makeBasePoseAsset(path: "poses/newer.png")]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: olderDirectory.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newerDirectory.path
        )

        try CharacterPackageSelectionStore().save(
            CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: ["luke": olderID]
            ),
            to: animateURL
        )

        let library = CharacterPackageLibrary()
        let packages = library.installedPackages(for: "luke", in: animateURL)

        XCTAssertEqual(packages.map(\.manifest.id), [olderID, newerID])
        XCTAssertEqual(library.activePackage(for: "luke", in: animateURL)?.id, olderID)
    }

    func testSelectionStoreRoundTripsSelections() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let lukeID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let amiraID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

        let store = CharacterPackageSelectionStore()
        try store.save(
            CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: [
                    "luke": lukeID,
                    "amira": amiraID
                ]
            ),
            to: animateURL
        )

        let manifest = store.load(from: animateURL)

        XCTAssertEqual(manifest.activePackageIDsByCharacterSlug["luke"], lukeID)
        XCTAssertEqual(manifest.activePackageIDsByCharacterSlug["amira"], amiraID)
        XCTAssertEqual(store.activePackageID(for: "luke", in: animateURL), lukeID)
        XCTAssertEqual(store.activePackageID(for: "amira", in: animateURL), amiraID)
    }

    func testRenderResolverDoesNotFallbackPastExplicitBrokenActivePackage() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let brokenID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let fallbackID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let characterSlug = "luke"

        let packagesDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(characterSlug)
            .appendingPathComponent("packages")

        let brokenDirectory = packagesDirectory.appendingPathComponent(brokenID.uuidString)
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try writeManifest(
            CharacterPackageManifest(
                id: brokenID,
                slug: characterSlug,
                displayName: "Broken Active",
                assets: [
                    CharacterPackageAsset(
                        role: .basePose,
                        name: "Missing Base",
                        angle: .front,
                        pose: .frontal,
                        relativePath: "poses/missing.png"
                    )
                ]
            ),
            to: brokenDirectory
        )

        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: fallbackID,
                slug: characterSlug,
                displayName: "Renderable Fallback",
                assets: [makeBasePoseAsset(path: "poses/base.png")]
            ),
            animateURL: animateURL,
            characterSlug: characterSlug
        )

        try CharacterPackageSelectionStore().save(
            CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: [characterSlug: brokenID]
            ),
            to: animateURL
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: characterSlug,
            parts: []
        )

        let renderPlan = CharacterPackageRenderResolver().resolveRenderPlan(
            for: character,
            animateURL: animateURL
        )

        XCTAssertNil(renderPlan)
    }

    func testPackagePreviewRenderResolverHonorsExplicitActivePackageSelection() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let explicitID = UUID(uuidString: "45454545-4545-4545-4545-454545454545")!
        let newerID = UUID(uuidString: "67676767-6767-6767-6767-676767676767")!
        let characterSlug = "luke"

        let explicitDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: explicitID,
                slug: characterSlug,
                displayName: "Explicit Preview",
                assets: [makeBasePoseAsset(path: "poses/explicit.png")]
            ),
            animateURL: animateURL,
            characterSlug: characterSlug
        )
        let newerDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: newerID,
                slug: characterSlug,
                displayName: "Newer Preview",
                assets: [makeBasePoseAsset(path: "poses/newer.png")]
            ),
            animateURL: animateURL,
            characterSlug: characterSlug
        )

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: explicitDirectory.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newerDirectory.path
        )

        try CharacterPackageSelectionStore().save(
            CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: [characterSlug: explicitID]
            ),
            to: animateURL
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: characterSlug,
            renderMode: .packagePreview,
            parts: []
        )

        let renderPlan = try XCTUnwrap(
            CharacterPackageRenderResolver().resolveRenderPlan(
                for: character,
                animateURL: animateURL
            )
        )

        XCTAssertEqual(renderPlan.package.id, explicitID)
        XCTAssertEqual(renderPlan.package.manifest.displayName, "Explicit Preview")
        XCTAssertEqual(renderPlan.mode.rawValue, CharacterPackageResolvedRenderPlan.Mode.wholeCharacter.rawValue)
        XCTAssertEqual(renderPlan.layers.first?.assetURL.lastPathComponent, "explicit.png")
    }

    func testRigRenderResolverUsesSyncedVariantsIndependentOfPackagePreview() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("chest.png"))
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("head.png"))

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            renderMode: .rigDrawingSets,
            parts: [
                RigPart(
                    name: "Chest",
                    partType: .chest,
                    zOrder: 3,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            variants: [
                                DrawingVariant(
                                    name: "Chest Synced",
                                    filename: "chest.png",
                                    sourcePackageID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                                    placement: CharacterPackageAssetPlacement(
                                        normalizedCenter: CharacterPackageNormalizedPoint(x: 0.5, y: 0.48),
                                        normalizedSize: CharacterPackageNormalizedSize(width: 0.42, height: 0.34)
                                    )
                                )
                            ]
                        )
                    ]
                ),
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 5,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            variants: [
                                DrawingVariant(
                                    name: "Head Synced",
                                    filename: "head.png",
                                    sourcePackageID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                                    placement: CharacterPackageAssetPlacement(
                                        normalizedCenter: CharacterPackageNormalizedPoint(x: 0.5, y: 0.22),
                                        normalizedSize: CharacterPackageNormalizedSize(width: 0.28, height: 0.24)
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(for: character, animateURL: animateURL)
        )

        XCTAssertEqual(renderPlan.angle, .front)
        XCTAssertEqual(renderPlan.layers.map { $0.part.partType }, [.chest, .head])
        XCTAssertEqual(renderPlan.layers.map(\.zOrder), [3, 5])
    }

    func testRigRenderResolverUsesInstalledPackageCanvasHintWhenSourcePackageMatches() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let packageID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: packageID,
                slug: "luke",
                displayName: "Rig Hint Luke",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal,
                    defaultCanvasSize: CharacterPackageCanvasSize(width: 1024, height: 1536)
                ),
                assets: [makeBasePoseAsset(path: "poses/base.png")]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("head.png"))

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            renderMode: .rigDrawingSets,
            parts: [
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 5,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            variants: [
                                DrawingVariant(
                                    name: "Head Synced",
                                    filename: "head.png",
                                    sourcePackageID: packageID,
                                    sourcePackageSlug: "luke"
                                )
                            ]
                        )
                    ]
                )
            ]
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(for: character, animateURL: animateURL)
        )

        XCTAssertEqual(renderPlan.packageCanvasSizeHint?.width, 1024)
        XCTAssertEqual(renderPlan.packageCanvasSizeHint?.height, 1536)
    }

    func testRigRenderResolverPreservesActiveVariantAcrossSubsequentSyncs() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let previewPackageID = UUID(uuidString: "82828282-8282-8282-8282-828282828282")!
        let syncedPackageID = UUID(uuidString: "93939393-9393-9393-9393-939393939393")!
        let characterSlug = "luke"

        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: previewPackageID,
                slug: characterSlug,
                displayName: "Preview Package",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal,
                    defaultCanvasSize: CharacterPackageCanvasSize(width: 900, height: 1200)
                ),
                assets: [
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Preview",
                        partType: .head,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/head-preview.png",
                        tags: ["part-layer"]
                    )
                ]
            ),
            animateURL: animateURL,
            characterSlug: characterSlug
        )
        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: syncedPackageID,
                slug: characterSlug,
                displayName: "Rig Sync Package",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal,
                    defaultCanvasSize: CharacterPackageCanvasSize(width: 1024, height: 1536)
                ),
                assets: [
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Synced",
                        partType: .head,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/head-synced.png",
                        tags: ["part-layer"]
                    )
                ]
            ),
            animateURL: animateURL,
            characterSlug: characterSlug
        )

        try CharacterPackageSelectionStore().save(
            CharacterPackageSelectionManifest(
                activePackageIDsByCharacterSlug: [characterSlug: previewPackageID]
            ),
            to: animateURL
        )

        let packages = CharacterPackageLibrary().installedPackages(for: characterSlug, in: animateURL)
        let previewPackage = try XCTUnwrap(packages.first(where: { $0.id == previewPackageID }))
        let syncedPackage = try XCTUnwrap(packages.first(where: { $0.id == syncedPackageID }))

        let baseCharacter = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: characterSlug,
            renderMode: .rigDrawingSets,
            parts: [RigPart(name: "Head", partType: .head, zOrder: 5)]
        )

        let syncService = CharacterPackageRigSyncService()
        let firstSync = try syncService.sync(
            character: baseCharacter,
            package: previewPackage,
            animateURL: animateURL,
            createdDefaultRig: false
        )
        let previewSyncedCharacter = AnimationCharacter(
            id: baseCharacter.id,
            name: baseCharacter.name,
            description: baseCharacter.description,
            owpSlug: baseCharacter.owpSlug,
            renderMode: .rigDrawingSets,
            parts: firstSync.parts
        )

        let secondSync = try syncService.sync(
            character: previewSyncedCharacter,
            package: syncedPackage,
            animateURL: animateURL,
            createdDefaultRig: false
        )
        let renderCharacter = AnimationCharacter(
            id: baseCharacter.id,
            name: baseCharacter.name,
            description: baseCharacter.description,
            owpSlug: baseCharacter.owpSlug,
            renderMode: .rigDrawingSets,
            parts: secondSync.parts
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(
                for: renderCharacter,
                animateURL: animateURL
            )
        )
        let variants = try XCTUnwrap(
            secondSync.parts.first(where: { $0.partType == .head })?.drawingSets[.front]?.variants
        )
        let layer = try XCTUnwrap(renderPlan.layers.first)

        XCTAssertEqual(CharacterPackageLibrary().activePackage(for: characterSlug, in: animateURL)?.id, previewPackageID)
        XCTAssertEqual(variants.map(\.sourcePackageID), [previewPackageID, syncedPackageID])
        XCTAssertEqual(layer.variant.sourcePackageID, previewPackageID)
        XCTAssertEqual(layer.variant.sourcePackageDisplayName, "Preview Package")
        XCTAssertEqual(renderPlan.packageCanvasSizeHint?.width, 900)
        XCTAssertEqual(renderPlan.packageCanvasSizeHint?.height, 1200)
    }

    func testDrawingSetResolvedActiveVariantPrefersExplicitSelection() {
        let first = DrawingVariant(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "First",
            filename: "first.png"
        )
        let second = DrawingVariant(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Second",
            filename: "second.png"
        )

        let drawingSet = DrawingSet(
            angle: .front,
            activeVariantID: first.id,
            variants: [first, second]
        )

        XCTAssertEqual(drawingSet.resolvedActiveVariant?.id, first.id)
    }

    func testRigRenderResolverUsesExplicitActiveVariantOverLatest() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("first.png"))
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("second.png"))

        let selectedVariant = DrawingVariant(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Selected",
            filename: "first.png"
        )
        let latestVariant = DrawingVariant(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Latest",
            filename: "second.png"
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            renderMode: .rigDrawingSets,
            parts: [
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 5,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            activeVariantID: selectedVariant.id,
                            variants: [selectedVariant, latestVariant]
                        )
                    ]
                )
            ]
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(for: character, animateURL: animateURL)
        )

        XCTAssertEqual(renderPlan.layers.first?.variant.id, selectedVariant.id)
    }

    func testRigRenderResolverPrefersSemanticExpressionVariantWhenCueMatches() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("default-head.png"))
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("determined-head.png"))

        let defaultVariant = DrawingVariant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Default Head",
            filename: "default-head.png",
            sourceTags: ["default"]
        )
        let expressionVariant = DrawingVariant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Determined Head",
            filename: "determined-head.png",
            sourceAssetRole: .expression,
            sourcePose: .action,
            sourceTags: ["determined", "heroic"]
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            renderMode: .rigDrawingSets,
            parts: [
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 5,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            activeVariantID: defaultVariant.id,
                            variants: [defaultVariant, expressionVariant]
                        )
                    ]
                )
            ]
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(
                for: character,
                animateURL: animateURL,
                selection: CharacterRenderSelectionContext(expressionCue: "determined")
            )
        )

        XCTAssertEqual(renderPlan.layers.first?.variant.id, expressionVariant.id)
    }

    func testRigRenderResolverPrefersVisemeVariantWhenMouthCueMatches() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("mouth-rest.png"))
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("mouth-mbp.png"))

        let defaultVariant = DrawingVariant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000101")!,
            name: "Rest Mouth",
            filename: "mouth-rest.png",
            sourceTags: ["default", "rest"]
        )
        let visemeVariant = DrawingVariant(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000102")!,
            name: "MBP Mouth",
            filename: "mouth-mbp.png",
            sourceAssetRole: .viseme,
            sourceTags: ["mbp", "viseme"]
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            renderMode: .rigDrawingSets,
            parts: [
                RigPart(
                    name: "Mouth",
                    partType: .mouth,
                    zOrder: 21,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            activeVariantID: defaultVariant.id,
                            variants: [defaultVariant, visemeVariant]
                        )
                    ]
                )
            ]
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(
                for: character,
                animateURL: animateURL,
                selection: CharacterRenderSelectionContext(mouthCue: "viseme:mbp")
            )
        )

        XCTAssertEqual(renderPlan.layers.first?.variant.id, visemeVariant.id)
    }

    func testRigRenderResolverPrefersRequestedAngleWhenSelectionOverridesActiveFront() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("front-head.png"))
        try writeRenderablePlaceholder(at: partsDirectory.appendingPathComponent("side-head.png"))

        let frontVariant = DrawingVariant(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            name: "Front Head",
            filename: "front-head.png",
            sourceAngle: .front
        )
        let sideVariant = DrawingVariant(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            name: "Side Head",
            filename: "side-head.png",
            sourceAngle: .side
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            renderMode: .rigDrawingSets,
            parts: [
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 5,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            activeVariantID: frontVariant.id,
                            variants: [frontVariant]
                        ),
                        .side: DrawingSet(
                            angle: .side,
                            variants: [sideVariant]
                        )
                    ]
                )
            ]
        )

        let renderPlan = try XCTUnwrap(
            CharacterRigRenderResolver().resolveRenderPlan(
                for: character,
                animateURL: animateURL,
                selection: CharacterRenderSelectionContext(preferredAngle: .side)
            )
        )

        XCTAssertEqual(renderPlan.angle, .side)
        XCTAssertEqual(renderPlan.layers.first?.variant.id, sideVariant.id)
    }

    func testRigAssemblerBuildsLayeredPlanWhenPartAssetsExist() throws {
        let packageDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageDirectory) }

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Layered Luke",
            defaults: CharacterPackageDefaults(
                preferredAngle: .front,
                preferredPose: .frontal,
                defaultCanvasSize: CharacterPackageCanvasSize(width: 1024, height: 1536)
            ),
            assets: [
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Chest Layer",
                    partType: .chest,
                    angle: .front,
                    pose: .frontal,
                    relativePath: "parts/chest.png"
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Head Layer",
                    partType: .head,
                    angle: .front,
                    pose: .frontal,
                    relativePath: "parts/head.png"
                ),
                makeBasePoseAsset(path: "poses/base.png")
            ]
        )

        try writeManifest(manifest, to: packageDirectory)
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("parts/chest.png"))
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("parts/head.png"))
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("poses/base.png"))

        let installedPackage = InstalledCharacterPackage(
            manifest: manifest,
            manifestURL: packageDirectory.appendingPathComponent("character-package.json"),
            packageDirectoryURL: packageDirectory,
            validationReport: CharacterPackageValidator().validate(manifest),
            importedAt: Date()
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [
                RigPart(name: "Chest", partType: .chest, zOrder: 3),
                RigPart(name: "Head", partType: .head, zOrder: 5)
            ]
        )

        let plan = try XCTUnwrap(CharacterPackageRigAssembler().assemble(character: character, package: installedPackage))
        XCTAssertEqual(plan.mode.rawValue, CharacterPackageResolvedRenderPlan.Mode.layeredParts.rawValue)
        XCTAssertEqual(plan.layers.map { $0.asset.partType }, [.chest, .head])
        XCTAssertEqual(plan.layers.map(\.zOrder), [3, 5])
    }

    func testRigAssemblerFallsBackToWholeCharacterAsset() throws {
        let packageDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageDirectory) }

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Whole Character Luke",
            assets: [makeBasePoseAsset(path: "poses/base.png")]
        )

        try writeManifest(manifest, to: packageDirectory)
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("poses/base.png"))

        let installedPackage = InstalledCharacterPackage(
            manifest: manifest,
            manifestURL: packageDirectory.appendingPathComponent("character-package.json"),
            packageDirectoryURL: packageDirectory,
            validationReport: CharacterPackageValidator().validate(manifest),
            importedAt: Date()
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )

        let plan = try XCTUnwrap(CharacterPackageRigAssembler().assemble(character: character, package: installedPackage))
        XCTAssertEqual(plan.mode.rawValue, CharacterPackageResolvedRenderPlan.Mode.wholeCharacter.rawValue)
        XCTAssertEqual(plan.layers.count, 1)
        XCTAssertEqual(plan.layers.first?.asset.role, .basePose)
    }

    func testRigAssemblerUsesAuthoredPlacementWithoutHeuristicLayout() throws {
        let packageDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageDirectory) }

        let rootAsset = CharacterPackageAsset(
            role: .costumeOverlay,
            name: "Root Layer",
            partType: .root,
            angle: .front,
            pose: .frontal,
            placement: CharacterPackageAssetPlacement(
                normalizedCenter: CharacterPackageNormalizedPoint(x: 0.52, y: 0.64),
                normalizedSize: CharacterPackageNormalizedSize(width: 0.76, height: 1.08)
            ),
            relativePath: "parts/root.png"
        )

        let headAsset = CharacterPackageAsset(
            role: .costumeOverlay,
            name: "Head Layer",
            partType: .head,
            angle: .front,
            pose: .frontal,
            relativePath: "parts/head.png"
        )

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Authored Placement Luke",
            assets: [rootAsset, headAsset]
        )

        try writeManifest(manifest, to: packageDirectory)
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("parts/root.png"))
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("parts/head.png"))

        let installedPackage = InstalledCharacterPackage(
            manifest: manifest,
            manifestURL: packageDirectory.appendingPathComponent("character-package.json"),
            packageDirectoryURL: packageDirectory,
            validationReport: CharacterPackageValidator().validate(manifest),
            importedAt: Date()
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [
                RigPart(name: "Root", partType: .root, zOrder: 1),
                RigPart(name: "Head", partType: .head, zOrder: 5)
            ]
        )

        let plan = try XCTUnwrap(CharacterPackageRigAssembler().assemble(character: character, package: installedPackage))
        let rootLayer = try XCTUnwrap(plan.layers.first(where: { $0.asset.partType == .root }))

        XCTAssertEqual(plan.mode.rawValue, CharacterPackageResolvedRenderPlan.Mode.layeredParts.rawValue)
        XCTAssertEqual(rootLayer.normalizedCenter.x, Float(0.52), accuracy: 0.0001)
        XCTAssertEqual(rootLayer.normalizedCenter.y, Float(0.64), accuracy: 0.0001)
        XCTAssertEqual(rootLayer.normalizedSizeHint.x, Float(0.76), accuracy: 0.0001)
        XCTAssertEqual(rootLayer.normalizedSizeHint.y, Float(1.08), accuracy: 0.0001)
    }

    func testRigAssemblerUsesAuthoredPlacementForWholeCharacterAsset() throws {
        let packageDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageDirectory) }

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Placed Whole Character Luke",
            assets: [
                CharacterPackageAsset(
                    role: .basePose,
                    name: "Base",
                    angle: .front,
                    pose: .frontal,
                    placement: CharacterPackageAssetPlacement(
                        normalizedCenter: CharacterPackageNormalizedPoint(x: 0.46, y: 0.58),
                        normalizedSize: CharacterPackageNormalizedSize(width: 0.64, height: 0.92)
                    ),
                    relativePath: "poses/base.png",
                    tags: ["default", "render"]
                )
            ]
        )

        try writeManifest(manifest, to: packageDirectory)
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("poses/base.png"))

        let installedPackage = InstalledCharacterPackage(
            manifest: manifest,
            manifestURL: packageDirectory.appendingPathComponent("character-package.json"),
            packageDirectoryURL: packageDirectory,
            validationReport: CharacterPackageValidator().validate(manifest),
            importedAt: Date()
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )

        let plan = try XCTUnwrap(CharacterPackageRigAssembler().assemble(character: character, package: installedPackage))
        let layer = try XCTUnwrap(plan.layers.first)

        XCTAssertEqual(plan.mode.rawValue, CharacterPackageResolvedRenderPlan.Mode.wholeCharacter.rawValue)
        XCTAssertEqual(layer.normalizedCenter.x, Float(0.46), accuracy: 0.0001)
        XCTAssertEqual(layer.normalizedCenter.y, Float(0.58), accuracy: 0.0001)
        XCTAssertEqual(layer.normalizedSizeHint.x, Float(0.64), accuracy: 0.0001)
        XCTAssertEqual(layer.normalizedSizeHint.y, Float(0.92), accuracy: 0.0001)
    }

    func testRigAssemblerHonorsPlacementZOrderOverride() throws {
        let packageDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageDirectory) }

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Z Ordered Luke",
            assets: [
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Head Layer",
                    partType: .head,
                    angle: .front,
                    pose: .frontal,
                    placement: CharacterPackageAssetPlacement(zOrderOverride: 2),
                    relativePath: "parts/head.png"
                ),
                CharacterPackageAsset(
                    role: .costumeOverlay,
                    name: "Chest Layer",
                    partType: .chest,
                    angle: .front,
                    pose: .frontal,
                    placement: CharacterPackageAssetPlacement(zOrderOverride: 10),
                    relativePath: "parts/chest.png"
                )
            ]
        )

        try writeManifest(manifest, to: packageDirectory)
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("parts/head.png"))
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("parts/chest.png"))

        let installedPackage = InstalledCharacterPackage(
            manifest: manifest,
            manifestURL: packageDirectory.appendingPathComponent("character-package.json"),
            packageDirectoryURL: packageDirectory,
            validationReport: CharacterPackageValidator().validate(manifest),
            importedAt: Date()
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [
                RigPart(name: "Chest", partType: .chest, zOrder: 40),
                RigPart(name: "Head", partType: .head, zOrder: 5)
            ]
        )

        let plan = try XCTUnwrap(CharacterPackageRigAssembler().assemble(character: character, package: installedPackage))
        XCTAssertEqual(plan.layers.map(\.zOrder), [2, 10])
        XCTAssertEqual(plan.layers.map { $0.asset.partType }, [.head, .chest])
    }

    func testRigAssemblerPrefersSemanticPoseAndAngleForWholeCharacterAsset() throws {
        let packageDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: packageDirectory) }

        let manifest = CharacterPackageManifest(
            slug: "luke",
            displayName: "Semantic Whole Character Luke",
            defaults: CharacterPackageDefaults(preferredAngle: .front, preferredPose: .frontal),
            assets: [
                CharacterPackageAsset(
                    role: .basePose,
                    name: "Front Neutral",
                    angle: .front,
                    pose: .frontal,
                    relativePath: "poses/front-neutral.png",
                    tags: ["default", "render"]
                ),
                CharacterPackageAsset(
                    role: .heroPose,
                    name: "Side Walking",
                    angle: .side,
                    pose: .walking,
                    relativePath: "poses/side-walking.png",
                    tags: ["walking", "side"]
                )
            ]
        )

        try writeManifest(manifest, to: packageDirectory)
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("poses/front-neutral.png"))
        try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent("poses/side-walking.png"))

        let installedPackage = InstalledCharacterPackage(
            manifest: manifest,
            manifestURL: packageDirectory.appendingPathComponent("character-package.json"),
            packageDirectoryURL: packageDirectory,
            validationReport: CharacterPackageValidator().validate(manifest),
            importedAt: Date()
        )

        let plan = try XCTUnwrap(
            CharacterPackageRigAssembler().assemble(
                character: AnimationCharacter(
                    id: UUID(),
                    name: "Luke",
                    description: "",
                    owpSlug: "luke",
                    parts: []
                ),
                package: installedPackage,
                selection: CharacterRenderSelectionContext(
                    preferredAngle: .side,
                    preferredPose: .walking,
                    actionCue: "walk"
                )
            )
        )

        XCTAssertEqual(plan.layers.first?.asset.name, "Side Walking")
    }

    func testRigSyncImportsMatchingVariantsAndSkipsDuplicates() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let packageID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: packageID,
                slug: "luke",
                displayName: "Syncable Luke",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal
                ),
                assets: [
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Layer",
                        partType: .head,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/head.png",
                        tags: ["part-layer"]
                    ),
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Chest Layer",
                        partType: .chest,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/chest.png",
                        tags: ["part-layer"]
                    )
                ]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        let package = try XCTUnwrap(
            CharacterPackageLibrary().activePackage(for: "luke", in: animateURL)
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [
                RigPart(name: "Chest", partType: .chest, zOrder: 3),
                RigPart(name: "Head", partType: .head, zOrder: 5)
            ]
        )

        let service = CharacterPackageRigSyncService()
        let first = try service.sync(
            character: character,
            package: package,
            animateURL: animateURL,
            createdDefaultRig: false
        )

        XCTAssertEqual(first.report.importedVariants, 2)
        XCTAssertEqual(first.report.skippedExistingVariants, 0)
        XCTAssertEqual(first.report.matchedPartAssets, 2)
        XCTAssertTrue(first.report.missingRigPartTypes.isEmpty)

        let headSet = try XCTUnwrap(first.parts.first(where: { $0.partType == .head })?.drawingSets[.front])
        let chestSet = try XCTUnwrap(first.parts.first(where: { $0.partType == .chest })?.drawingSets[.front])
        XCTAssertEqual(headSet.variants.count, 1)
        XCTAssertEqual(chestSet.variants.count, 1)

        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
        let copiedFiles = try FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)
        XCTAssertEqual(copiedFiles.count, 2)

        let syncedCharacter = AnimationCharacter(
            id: character.id,
            name: character.name,
            description: character.description,
            owpSlug: character.owpSlug,
            parts: first.parts
        )

        let second = try service.sync(
            character: syncedCharacter,
            package: package,
            animateURL: animateURL,
            createdDefaultRig: false
        )

        XCTAssertEqual(second.report.importedVariants, 0)
        XCTAssertEqual(second.report.skippedExistingVariants, 2)
        XCTAssertEqual(second.parts.first(where: { $0.partType == .head })?.drawingSets[.front]?.variants.count, 1)
        XCTAssertEqual(second.parts.first(where: { $0.partType == .chest })?.drawingSets[.front]?.variants.count, 1)
    }

    func testRigSyncStoresPackageSourceAndPlacementMetadata() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let packageID = UUID(uuidString: "91919191-9191-9191-9191-919191919191")!
        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: packageID,
                slug: "luke",
                displayName: "Placement Rich Luke",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal
                ),
                assets: [
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Layer",
                        partType: .head,
                        angle: .front,
                        pose: .frontal,
                        placement: CharacterPackageAssetPlacement(
                            mode: .fullCanvasAligned,
                            normalizedCenter: CharacterPackageNormalizedPoint(x: 0.5, y: 0.5),
                            normalizedSize: CharacterPackageNormalizedSize(width: 0.72, height: 1.0),
                            normalizedPivot: CharacterPackageNormalizedPoint(x: 0.5, y: 0.2),
                            zOrderOverride: 7,
                            usesFullCanvasPlacement: true
                        ),
                        relativePath: "parts/head.png",
                        tags: ["part-layer", "determined"],
                        notes: "Determined expression head layer"
                    )
                ]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        let package = try XCTUnwrap(
            CharacterPackageLibrary().activePackage(for: "luke", in: animateURL)
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [RigPart(name: "Head", partType: .head, zOrder: 5)]
        )

        let result = try CharacterPackageRigSyncService().sync(
            character: character,
            package: package,
            animateURL: animateURL,
            createdDefaultRig: false
        )

        let variant = try XCTUnwrap(result.parts.first?.drawingSets[.front]?.variants.first)
        XCTAssertEqual(variant.sourcePackageSchemaVersion, 2)
        XCTAssertEqual(variant.sourcePackageID, packageID)
        XCTAssertEqual(variant.sourcePackageSlug, "luke")
        XCTAssertEqual(variant.sourcePackageDisplayName, "Placement Rich Luke")
        XCTAssertEqual(variant.sourceAssetName, "Head Layer")
        XCTAssertEqual(variant.sourceAssetRole, .costumeOverlay)
        XCTAssertEqual(variant.sourcePartType, .head)
        XCTAssertEqual(variant.sourceAngle, .front)
        XCTAssertEqual(variant.sourcePose, .frontal)
        XCTAssertEqual(variant.sourceTags ?? [], ["part-layer", "determined"])
        XCTAssertEqual(variant.sourceNotes, "Determined expression head layer")
        XCTAssertEqual(variant.placement?.resolvedMode, .fullCanvasAligned)
        let pivot = try XCTUnwrap(variant.placement?.normalizedPivot)
        XCTAssertEqual(pivot.y, 0.2, accuracy: 0.0001)
        XCTAssertEqual(variant.placement?.zOrderOverride, 7)
    }

    func testRigSyncPreservesMultipleAnglesForTheSamePartType() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let packageID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        _ = try installPackage(
            manifest: CharacterPackageManifest(
                id: packageID,
                slug: "luke",
                displayName: "Angle Rich Luke",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal
                ),
                assets: [
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Front",
                        partType: .head,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/head/front.png",
                        tags: ["part-layer"]
                    ),
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Side",
                        partType: .head,
                        angle: .side,
                        pose: .profile,
                        relativePath: "parts/head/side.png",
                        tags: ["part-layer"]
                    )
                ]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        let package = try XCTUnwrap(
            CharacterPackageLibrary().activePackage(for: "luke", in: animateURL)
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [
                RigPart(name: "Head", partType: .head, zOrder: 5)
            ]
        )

        let result = try CharacterPackageRigSyncService().sync(
            character: character,
            package: package,
            animateURL: animateURL,
            createdDefaultRig: false
        )

        let head = try XCTUnwrap(result.parts.first(where: { $0.partType == .head }))
        XCTAssertEqual(head.drawingSets[.front]?.variants.count, 1)
        XCTAssertEqual(head.drawingSets[.side]?.variants.count, 1)
        XCTAssertEqual(result.report.importedVariants, 2)
    }

    func testRigSyncUsesUniqueFilenamesPerAssetAndRefreshesExistingCopies() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let packageID = UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        let packageDirectory = try installPackage(
            manifest: CharacterPackageManifest(
                id: packageID,
                slug: "luke",
                displayName: "Collision Safe Luke",
                defaults: CharacterPackageDefaults(
                    preferredAngle: .front,
                    preferredPose: .frontal
                ),
                assets: [
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Head Front",
                        partType: .head,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/head/front.png",
                        tags: ["part-layer"]
                    ),
                    CharacterPackageAsset(
                        role: .costumeOverlay,
                        name: "Chest Front",
                        partType: .chest,
                        angle: .front,
                        pose: .frontal,
                        relativePath: "parts/chest/front.png",
                        tags: ["part-layer"]
                    )
                ]
            ),
            animateURL: animateURL,
            characterSlug: "luke"
        )

        let package = try XCTUnwrap(
            CharacterPackageLibrary().activePackage(for: "luke", in: animateURL)
        )

        let character = AnimationCharacter(
            id: UUID(),
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: [
                RigPart(name: "Chest", partType: .chest, zOrder: 3),
                RigPart(name: "Head", partType: .head, zOrder: 5)
            ]
        )

        let first = try CharacterPackageRigSyncService().sync(
            character: character,
            package: package,
            animateURL: animateURL,
            createdDefaultRig: false
        )

        let headFilename = try XCTUnwrap(
            first.parts.first(where: { $0.partType == .head })?.drawingSets[.front]?.variants.first?.filename
        )
        let chestFilename = try XCTUnwrap(
            first.parts.first(where: { $0.partType == .chest })?.drawingSets[.front]?.variants.first?.filename
        )
        XCTAssertNotEqual(headFilename, chestFilename)

        let headSourceURL = packageDirectory.appendingPathComponent("parts/head/front.png")
        let headDestinationURL = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent("luke")
            .appendingPathComponent("parts")
            .appendingPathComponent(headFilename)

        try Data("updated-head".utf8).write(to: headSourceURL)

        let syncedCharacter = AnimationCharacter(
            id: character.id,
            name: character.name,
            description: character.description,
            owpSlug: character.owpSlug,
            parts: first.parts
        )

        let second = try CharacterPackageRigSyncService().sync(
            character: syncedCharacter,
            package: package,
            animateURL: animateURL,
            createdDefaultRig: false
        )

        XCTAssertEqual(second.report.importedVariants, 0)
        XCTAssertEqual(second.report.skippedExistingVariants, 2)
        XCTAssertEqual(try Data(contentsOf: headDestinationURL), Data("updated-head".utf8))
    }

    private func makeBasePoseAsset(path: String) -> CharacterPackageAsset {
        CharacterPackageAsset(
            role: .basePose,
            name: "Base",
            angle: .front,
            pose: .frontal,
            relativePath: path,
            tags: ["default", "render"]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePackageDirectory(manifest: CharacterPackageManifest) throws -> URL {
        let packageURL = try makeTemporaryDirectory()
        try writeManifest(manifest, to: packageURL)
        for asset in manifest.assets {
            try writeRenderablePlaceholder(at: packageURL.appendingPathComponent(asset.normalizedRelativePath))
        }
        return packageURL
    }

    @discardableResult
    private func installPackage(
        manifest: CharacterPackageManifest,
        animateURL: URL,
        characterSlug: String
    ) throws -> URL {
        let packageDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(characterSlug)
            .appendingPathComponent("packages")
            .appendingPathComponent(manifest.id.uuidString)

        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try writeManifest(manifest, to: packageDirectory)
        for asset in manifest.assets {
            try writeRenderablePlaceholder(at: packageDirectory.appendingPathComponent(asset.normalizedRelativePath))
        }
        return packageDirectory
    }

    private func writeManifest(_ manifest: CharacterPackageManifest, to directory: URL) throws {
        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("character-package.json"))
    }

    private func writeRenderablePlaceholder(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    }
}
