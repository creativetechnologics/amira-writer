import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class ProjectDatabaseBridge3DRegistryTests: XCTestCase {
    func testSaveAndLoad3DRegistryManifestsRoundTrip() throws {
        let projectURL = try makeProjectURL()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)

        let assetRegistry = Animate3DAssetRegistry(
            bundles: [
                Animate3DCharacterBundleDescriptor(
                    characterSlug: "luke",
                    costumeName: "default",
                    bodyModelPath: "Animate/characters/luke/models/luke.glb",
                    faceRigPath: "Animate/characters/luke/face-rigs/face.json",
                    mouthProfilePath: "Animate/characters/luke/mouth-profiles/mouth.json",
                    expressionLibraryPath: "Animate/characters/luke/expressions/expressions.json",
                    motionSetPaths: ["Animate/characters/luke/motions/walk.json"],
                    materialProfilePath: "Animate/characters/luke/materials/lookdev.json"
                )
            ]
        )
        let characterRegistry = Animate3DCharacterRegistry(bundles: assetRegistry.bundles)
        let motionRegistry = Animate3DMotionRegistry(
            motions: [
                Animate3DMotionSetDescriptor(
                    motionID: "walk_cycle",
                    title: "Walk Cycle",
                    relativePath: "Animate/characters/luke/motions/walk.json",
                    tags: ["walk", "locomotion"],
                    notes: "Looped placeholder walk."
                )
            ]
        )
        let worldCatalog = Animate3DWorldCatalog(
            chunks: [
                Animate3DWorldChunkDescriptor(
                    worldID: "amira",
                    zoneID: "silver-corridor",
                    title: "Silver Corridor",
                    placeNames: ["Silver Corridor"],
                    meshPath: "Animate/3d/world-catalog/silver-corridor.glb",
                    depthMapPath: nil,
                    previewImagePath: "Animate/3d/world-catalog/silver-corridor.png",
                    styleProfileID: "amira-default",
                    atmospherePresetID: "corridor-atmo",
                    lightRigID: "corridor-rig"
                )
            ]
        )
        let styleProfiles = Animate3DStyleProfileManifest(
            profiles: [
                Animate3DStyleProfileDescriptor(
                    profileID: "amira-default",
                    title: "Amira Default",
                    notes: "Three-band cel shading.",
                    celBands: 3,
                    outlineWidth: 1.2
                )
            ]
        )
        let cameraPresets = Animate3DCameraPresetManifest(
            presets: [
                Animate3DCameraPresetDescriptor(
                    presetID: "wide-default",
                    title: "Wide",
                    shotName: "wide",
                    focalLength: 32,
                    notes: "Default wide."
                )
            ]
        )
        let lightRigs = Animate3DLightRigManifest(
            rigs: [
                Animate3DLightRigDescriptor(
                    rigID: "corridor-rig",
                    title: "Corridor Rig",
                    keyIntensity: 1100,
                    fillIntensity: 420,
                    rimIntensity: 260,
                    notes: "Cool fluorescent rig."
                )
            ]
        )
        let atmospherePresets = Animate3DAtmospherePresetManifest(
            presets: [
                Animate3DAtmospherePresetDescriptor(
                    presetID: "corridor-atmo",
                    title: "Corridor Atmosphere",
                    fogDensity: 0.1,
                    haze: 0.05,
                    colorHex: "#B4C3FF",
                    notes: "Cold interior."
                )
            ]
        )

        try ProjectDatabaseBridge.saveAnimate3DAssetRegistryToDisk(assetRegistry, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DCharacterRegistryToDisk(characterRegistry, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(motionRegistry, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DWorldCatalogToDisk(worldCatalog, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DStyleProfilesToDisk(styleProfiles, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DCameraPresetsToDisk(cameraPresets, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DLightRigsToDisk(lightRigs, projectURL: projectURL)
        try ProjectDatabaseBridge.saveAnimate3DAtmospherePresetsToDisk(atmospherePresets, projectURL: projectURL)

        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DAssetRegistryFromDisk(projectURL: projectURL), assetRegistry)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DCharacterRegistryFromDisk(projectURL: projectURL), characterRegistry)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DMotionRegistryFromDisk(projectURL: projectURL), motionRegistry)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DWorldCatalogFromDisk(projectURL: projectURL), worldCatalog)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DStyleProfilesFromDisk(projectURL: projectURL), styleProfiles)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DCameraPresetsFromDisk(projectURL: projectURL), cameraPresets)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DLightRigsFromDisk(projectURL: projectURL), lightRigs)
        XCTAssertEqual(ProjectDatabaseBridge.loadAnimate3DAtmospherePresetsFromDisk(projectURL: projectURL), atmospherePresets)
    }

    private func makeProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Animate3DRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
